--[[
	WowDamageInfo -- UI.lua
	Movable stat window, text rows, Reset/Lock buttons, slash commands.
]]

local ADDON, ns = ...

local stats = ns.stats
local format, floor = string.format, math.floor

local PADDING = 10
local LINE_HEIGHT = 14
local FRAME_WIDTH = 230
local UPDATE_INTERVAL = 0.2 -- redraw at most 5x/sec regardless of log volume

local SCHOOL_COLORS = {
	[0x02] = "FFF58CBA", -- Holy
	[0x04] = "FFFF7D0A", -- Fire
	[0x08] = "FFABD473", -- Nature
	[0x10] = "FF69CCF0", -- Frost
	[0x20] = "FF9482C9", -- Shadow
	[0x40] = "FFC79C6E", -- Arcane
}

local defaults = {
	point = "CENTER",
	relPoint = "CENTER",
	x = 0,
	y = 0,
	locked = false,
	shown = true,
}

local frame, lines, resetButton, lockButton
local db

local function FormatNum(n)
	n = n or 0
	if n >= 1000000 then
		return format("%.2fm", n / 1000000)
	elseif n >= 10000 then
		return format("%.1fk", n / 1000)
	end
	return tostring(floor(n + 0.5))
end

-- Percent guarded against an empty stat set.
local function Pct(part, whole)
	if not whole or whole <= 0 then return 0 end
	return part / whole * 100
end

local function GetLine(index)
	local line = lines[index]
	if not line then
		line = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		line:SetJustifyH("LEFT")
		line:SetWidth(FRAME_WIDTH - PADDING * 2)
		lines[index] = line
	end
	return line
end

local function UpdateDisplay()
	local n = 0
	local function Add(text)
		n = n + 1
		local line = GetLine(n)
		line:SetText(text)
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(24 + (n - 1) * LINE_HEIGHT))
		line:Show()
	end

	local total = stats.total

	Add(format("|cFFFFFFFFОбщий урон:|r %s", FormatNum(total)))
	Add(format("Физ: |cFFFFD100%s|r (%.0f%%) / Маг: |cFFFFD100%s|r (%.0f%%)",
		FormatNum(stats.physical), Pct(stats.physical, total),
		FormatNum(stats.magic), Pct(stats.magic, total)))
	-- "|" is the UI escape character, so a raw pipe separator is avoided here.
	Add(format("|cFF999999   автоатаки:|r %s  |cFF999999·  скиллы:|r %s",
		FormatNum(stats.melee), FormatNum(stats.spell)))

	-- Magic schools, non-empty only, in a stable order.
	local hasSchools = false
	local named = 0
	local function SchoolHeader()
		if not hasSchools then
			Add("|cFF666666--- по школам ---|r")
			hasSchools = true
		end
	end

	for _, school in ipairs(ns.SCHOOL_ORDER) do
		local amount = stats.schools[school]
		if amount and amount > 0 then
			SchoolHeader()
			named = named + amount
			Add(format("|c%s%s:|r %s (%.0f%%)",
				SCHOOL_COLORS[school], ns.SCHOOL_NAMES[school],
				FormatNum(amount), Pct(amount, total)))
		end
	end

	-- Multi-school damage (e.g. Frostfire = Frost|Fire) has no single name, so
	-- it lands here instead of silently vanishing from the breakdown.
	local mixed = stats.magic - named
	if mixed > 0 then
		SchoolHeader()
		Add(format("|cFFCCCCCCСмешанная:|r %s (%.0f%%)", FormatNum(mixed), Pct(mixed, total)))
	end

	Add("|cFF666666--- смягчение ---|r")
	Add(format("|cFFFFFFFFЗаблокировано:|r %s", FormatNum(stats.blocked)))
	Add(format("|cFFFFFFFFПоглощено:|r %s", FormatNum(stats.absorbed)))
	Add(format("|cFFFFFFFFСопротивление:|r %s", FormatNum(stats.resisted)))
	Add(format("|cFFFFFFFFПарир./Уклон.:|r %d раз", stats.avoidCount))

	-- Only quantifiable mitigation goes into this ratio. Dodge/parry/miss carry
	-- no damage amount in the combat log, so the damage they prevented is
	-- unknowable -- they stay a separate event count above.
	local prevented = stats.blocked + stats.absorbed + stats.resisted
	Add(format("|cFF00FF00Смягчено:|r %.1f%%", Pct(prevented, total + prevented)))

	for i = n + 1, #lines do
		lines[i]:Hide()
	end

	frame:SetHeight(24 + n * LINE_HEIGHT + PADDING)
	ns.dirty = false
end
ns.UpdateDisplay = UpdateDisplay

local function SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function ApplyLock()
	lockButton:SetText(db.locked and "Unlock" or "Lock")
end

local function ToggleLock()
	db.locked = not db.locked
	ApplyLock()
end

local function CreateUI()
	frame = CreateFrame("Frame", "WowDamageInfoFrame", UIParent)
	frame:SetWidth(FRAME_WIDTH)
	frame:SetHeight(160)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)

	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.75)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not db.locked then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -8)
	title:SetText("Входящий урон")

	lockButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	lockButton:SetWidth(50)
	lockButton:SetHeight(16)
	lockButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
	lockButton:SetScript("OnClick", ToggleLock)

	resetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	resetButton:SetWidth(50)
	resetButton:SetHeight(16)
	resetButton:SetPoint("RIGHT", lockButton, "LEFT", -3, 0)
	resetButton:SetText("Reset")
	resetButton:SetScript("OnClick", function()
		ns.ResetStats()
		UpdateDisplay()
	end)

	lines = {}

	-- Throttled redraw: the combat log fires dozens of times per second, but
	-- the window only needs to keep up with the eye.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(self, delta)
		elapsed = elapsed + delta
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0
		if ns.dirty then UpdateDisplay() end
	end)
end

local function SetupSlashCommands()
	SLASH_WOWDAMAGEINFO1 = "/wdi"
	SLASH_WOWDAMAGEINFO2 = "/dts" -- alias kept from the addon's former name
	SlashCmdList["WOWDAMAGEINFO"] = function(msg)
		local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

		if cmd == "reset" then
			ns.ResetStats()
			UpdateDisplay()
			DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00WowDamageInfo:|r статистика сброшена.")
		elseif cmd == "lock" then
			ToggleLock()
			DEFAULT_CHAT_FRAME:AddMessage(db.locked
				and "|cFF00FF00WowDamageInfo:|r окно зафиксировано."
				or "|cFF00FF00WowDamageInfo:|r окно разблокировано.")
		elseif cmd == "" then
			if frame:IsShown() then frame:Hide() else frame:Show() end
			db.shown = frame:IsShown()
		else
			DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00WowDamageInfo:|r /wdi  ·  /wdi reset  ·  /wdi lock")
		end
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addonName)
	if addonName ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")

	WowDamageInfoDB = WowDamageInfoDB or {}
	db = WowDamageInfoDB
	for k, v in pairs(defaults) do
		if db[k] == nil then db[k] = v end
	end

	CreateUI()
	SetupSlashCommands()
	ApplyPosition()
	ApplyLock()
	UpdateDisplay()

	if not db.shown then frame:Hide() end
end)

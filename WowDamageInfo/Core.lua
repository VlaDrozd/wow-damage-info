--[[
	WowDamageInfo -- Core.lua
	Combat log parsing and stat accumulation.

	Combat log signature on 3.3.5a (WotLK):
		timestamp, subevent, sourceGUID, sourceName, sourceFlags,
		destGUID, destName, destFlags, ...payload

	There are NO raid flags (Cataclysm+) and no hideCaster (MoP+) in this
	client, so the subevent-specific payload begins at select(9, ...).
]]

local ADDON, ns = ...

local band = bit.band
local select, max = select, math.max

-- Spell school bitmask
local SCHOOL_PHYSICAL = 0x01

ns.SCHOOL_ORDER = { 0x02, 0x04, 0x08, 0x10, 0x20, 0x40 }
ns.SCHOOL_NAMES = {
	[0x02] = "Свет",
	[0x04] = "Огонь",
	[0x08] = "Природа",
	[0x10] = "Лёд",
	[0x20] = "Тень",
	[0x40] = "Тайная",
}

local stats = {
	total = 0,
	physical = 0,
	magic = 0,
	melee = 0, -- damage from white/auto attacks
	spell = 0, -- damage from spells and abilities
	blocked = 0,
	absorbed = 0,
	resisted = 0,
	avoidCount = 0, -- dodge/parry/miss events; no damage amount exists for these
	schools = {},
}
ns.stats = stats

function ns.ResetStats()
	stats.total = 0
	stats.physical = 0
	stats.magic = 0
	stats.melee = 0
	stats.spell = 0
	stats.blocked = 0
	stats.absorbed = 0
	stats.resisted = 0
	stats.avoidCount = 0
	for k in pairs(stats.schools) do
		stats.schools[k] = nil
	end
	ns.dirty = true
end

--[[
	Single place where all damage math happens.

	`resisted`, `blocked` and `absorbed` here are the PARTIAL mitigation fields
	carried by a damage event. Full mitigation arrives separately as a MISSED
	event and is handled below -- both must be counted or the totals come out
	several times too low.

	`resisted` can be negative when the player has a vulnerability effect, so it
	is clamped rather than subtracted from the running total.
]]
local function AccumulateDamage(amount, school, resisted, blocked, absorbed, isMelee)
	amount = amount or 0
	school = school or SCHOOL_PHYSICAL

	stats.total = stats.total + amount

	if isMelee then
		stats.melee = stats.melee + amount
	else
		stats.spell = stats.spell + amount
	end

	-- Exactly Physical counts as physical; multi-school (e.g. Frostfire = 0x14)
	-- is treated as magic.
	if school == SCHOOL_PHYSICAL then
		stats.physical = stats.physical + amount
	else
		stats.magic = stats.magic + amount
		if band(school, SCHOOL_PHYSICAL) == 0 then
			stats.schools[school] = (stats.schools[school] or 0) + amount
		end
	end

	stats.resisted = stats.resisted + max(0, resisted or 0)
	stats.blocked = stats.blocked + max(0, blocked or 0)
	stats.absorbed = stats.absorbed + max(0, absorbed or 0)

	ns.dirty = true
end

local function AccumulateMiss(missType, amountMissed)
	amountMissed = max(0, amountMissed or 0)

	if missType == "ABSORB" then
		stats.absorbed = stats.absorbed + amountMissed
	elseif missType == "RESIST" then
		stats.resisted = stats.resisted + amountMissed
	elseif missType == "BLOCK" then
		stats.blocked = stats.blocked + amountMissed
	else
		-- DODGE / PARRY / MISS / EVADE / IMMUNE / DEFLECT: the log carries no
		-- damage amount, so only the event count is meaningful.
		stats.avoidCount = stats.avoidCount + 1
	end

	ns.dirty = true
end

-- Dispatch table rather than an if/elseif chain -- the combat log is a hot path.
local handlers = {}

-- SWING_DAMAGE: amount, overkill, school, resisted, blocked, absorbed, ...
handlers.SWING_DAMAGE = function(...)
	local amount, _, school, resisted, blocked, absorbed = select(9, ...)
	AccumulateDamage(amount, school, resisted, blocked, absorbed, true)
end

-- SPELL_DAMAGE: spellId, spellName, spellSchool, amount, overkill, school,
--               resisted, blocked, absorbed, ...
handlers.SPELL_DAMAGE = function(...)
	local _, _, spellSchool, amount, _, school, resisted, blocked, absorbed = select(9, ...)
	AccumulateDamage(amount, school or spellSchool, resisted, blocked, absorbed, false)
end
handlers.SPELL_PERIODIC_DAMAGE = handlers.SPELL_DAMAGE
handlers.RANGE_DAMAGE = handlers.SPELL_DAMAGE
handlers.DAMAGE_SHIELD = handlers.SPELL_DAMAGE
handlers.SPELL_BUILDING_DAMAGE = handlers.SPELL_DAMAGE

-- ENVIRONMENTAL_DAMAGE: environmentalType, amount, overkill, school, ...
handlers.ENVIRONMENTAL_DAMAGE = function(...)
	local _, amount, _, school, resisted, blocked, absorbed = select(9, ...)
	AccumulateDamage(amount, school, resisted, blocked, absorbed, false)
end

-- SWING_MISSED: missType, amountMissed
handlers.SWING_MISSED = function(...)
	local missType, amountMissed = select(9, ...)
	AccumulateMiss(missType, amountMissed)
end

-- SPELL_MISSED: spellId, spellName, spellSchool, missType, amountMissed
handlers.SPELL_MISSED = function(...)
	local _, _, _, missType, amountMissed = select(9, ...)
	AccumulateMiss(missType, amountMissed)
end
handlers.SPELL_PERIODIC_MISSED = handlers.SPELL_MISSED
handlers.RANGE_MISSED = handlers.SPELL_MISSED
handlers.DAMAGE_SHIELD_MISSED = handlers.SPELL_MISSED

local playerGUID

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		if not playerGUID then return end

		local subevent = select(2, ...)
		local handler = handlers[subevent]
		if not handler then return end

		-- Bail out before touching the payload for anything not aimed at us.
		if select(6, ...) ~= playerGUID then return end

		handler(...)
	elseif event == "PLAYER_LOGIN" then
		playerGUID = UnitGUID("player")
	end
end)

-- Regenerates SOLOABILITY_NEEDED.txt from the database plus the answers
-- already recorded. Deterministic: the questions come from the shipped
-- predicate, and an answered record simply stops being a question.
local MM = { MAX_EXPANSION = 11 }
local all = {}
function MM.AddMounts(t) for _, r in ipairs(t) do all[#all+1] = r end end
setmetatable(MM, { __index = function() return function() end end })
assert(loadfile("Data/Mounts.lua"))("MasterMountsWorldTour", MM)
local EXP = { [10] = "The War Within", [11] = "Midnight" }

-- verbatim from Contribute.lua, the `solo` gap test
local function unanswered(rec)
	if not (rec.obtainable and rec.category == "ACHIEVEMENT") then return false end
	if rec.solo ~= nil then return false end
	local exp = rec.expansion
	if exp and (MM.MAX_EXPANSION - exp) >= 2 then return false end
	return true
end

-- Which of these were answered BY HAND, as opposed to carrying a flag that
-- already shipped. Read from the layer itself so the file cannot drift from
-- what is actually recorded.
local byHand = {}
do
	local stub = setmetatable({
		OverrideMount = function(name, fields)
			if fields and fields.solo ~= nil then byHand[name] = fields.solo end
		end,
	}, { __index = function() return function() end end })
	local f = loadfile("Data/_source/Data_99zzZi_Soloability.lua")
	if f then f("MasterMountsWorldTour", stub) end
end

local open, answered = {}, {}
for _, r in ipairs(all) do
	if unanswered(r) then open[#open+1] = r
	elseif r.solo ~= nil and r.category == "ACHIEVEMENT" and r.obtainable
		and r.expansion and (MM.MAX_EXPANSION - r.expansion) < 2 then
		answered[#answered+1] = r
	end
end
local function byName(a, b)
	if (a.expansion or 0) ~= (b.expansion or 0) then return (a.expansion or 0) < (b.expansion or 0) end
	return (a.name or "") < (b.name or "")
end
table.sort(open, byName); table.sort(answered, byName)

local out = {}
local function add(s) out[#out+1] = s or "" end
local function wrap(text, indent)
	local line, res = "", {}
	for word in text:gmatch("%S+") do
		if #line + #word + 1 > 72 then res[#res+1] = indent .. line; line = word
		else line = (line == "") and word or (line .. " " .. word) end
	end
	if line ~= "" then res[#res+1] = indent .. line end
	return table.concat(res, "\n")
end

add("# Master Mounts - soloability judgements needed")
add("#")
local handCount = 0
for _ in pairs(byHand) do handCount = handCount + 1 end
if #open == 0 then
	add("# NOTHING OPEN. All of them are answered.")
	add("#")
	add(("# %d records in this window carry a judgement, %d of them answered by"):format(
		#answered, handCount))
	add("# hand. The rest carried a flag from the start.")
	add("#")
	add("# Re-run tools/gen_soloability_file.lua after a patch adds content --")
	add("# a new expansion pushes the one before it out of this window, and")
	add("# whatever arrives unjudged shows up here as questions again.")
else
	add(("# %d STILL OPEN, listed below. %d of the %d already judged in this"):format(
		#open, handCount, #answered))
	add("# window were answered by hand; the rest carried a flag from the start.")
	add("# Put yes or no after SOLO: on each one. Partial is fine -- a blank")
	add("# SOLO: is simply not yet answered, and costs nothing.")
end
add("#")
add("# THE QUESTION")
add("#")
add("#   Can one player finish this today, at current gear, with no group?")
add("#")
add("# Not \"was it designed for a group\" and not \"could a very good player")
add("# manage it\". The planner uses the answer to decide whether a goal is work")
add("# you can start tonight or work that needs other people organised first,")
add("# and those are different kinds of evening.")
add("#")
add("# WHY THIS CANNOT BE LOOKED UP")
add("#")
add("# No API exposes it. Wowhead does not carry it. It depends on class, gear")
add("# and patch, which is exactly why it is a judgement rather than a fact --")
add("# and why it is worth one line each rather than an invented rule.")
add("#")
add("# WHY ONLY THESE")
add("#")
add("# Content two expansions back is ALREADY treated as soloable unless its own")
add("# wording says otherwise -- rated, keystone, arena, battleground. That rule")
add("# lives in one place and is stated once, rather than being baked into a")
add("# hundred records. So everything through Dragonflight is settled and is not")
add("# asked about here. What age does not settle is the current tier and the")
add("# one before it, where a raid or a delve genuinely may still need a group.")
add("#")
add("# A BLANK BEATS A GUESS")
add("#")
add("# An unjudged goal is costed pessimistically, so it can never outrank real")
add("# work. A wrong yes sends somebody to content they cannot finish alone. If")
add("# you are unsure, say so in the margin and leave SOLO: empty.")
add("#")

local lastExp
for _, r in ipairs(open) do
	if r.expansion ~= lastExp then
		lastExp = r.expansion
		add("")
		add("# ---------------------------------------------------------------")
		add(("# %s"):format(EXP[r.expansion] or ("expansion " .. tostring(r.expansion))))
		add("# ---------------------------------------------------------------")
		add("")
	end
	local ach
	for _, c in ipairs(r.conditions or {}) do
		if c.type == "ACHIEVEMENT" then ach = c.name break end
	end
	add(r.name)
	add(("    achievement:  %s"):format(ach or "(none named)"))
	add(wrap(("source: %s"):format((r.source or "?"):gsub("%s+", " ")), "    "))
	add("    SOLO:")
	add("")
end

add("")
add("# ===============================================================")
add(("# ALREADY JUDGED -- %d records, of which %d were answered by hand"):format(
	#answered, handCount))
add("# ===============================================================")
add("#")
add("# (h) = answered by hand, in Data/_source/Data_99zzZi_Soloability.lua")
add("#")
for _, r in ipairs(answered) do
	add(("#   %s %-28s %s"):format(byHand[r.name] ~= nil and "(h)" or "   ",
		r.name, r.solo and "yes" or "no"))
end
io.write(table.concat(out, "\n"), "\n")

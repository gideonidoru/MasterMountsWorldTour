-- Master Mounts: how long YOU actually take.
--
-- Every "do 120" in the plan is a category default -- a dungeon is 15 minutes,
-- a raid is 25, a fishing cast is 20 seconds. Reasonable averages, and wrong
-- for any specific player. Someone soloing a legacy raid at current gear is
-- not taking 25 minutes, and the plan has no way to know that.
--
-- So: time the real thing. Enter an instance, leave it, and the elapsed time
-- folds into a running mean for that instance.
--
-- STORED AS A MEAN AND A COUNT, never a list.
--
--   new = (mean * n + sample) / (n + 1)
--
-- One number and one integer per instance, so a thousand clears cost exactly
-- what one costs. A log of every run would grow without bound in saved
-- variables for no extra accuracy.
--
-- PER CHARACTER, because the content does not set the pace -- you do.
--
-- The same raid falls over far faster to a hunter or a death knight than to a
-- warrior, and an account-wide mean would blend all of them into a number that
-- describes nobody. A character with no history starts from the category
-- default and learns its own pace from there, which is slower to become useful
-- but never confidently wrong about a character it has never watched.
local _, MM = ...

MM.ClearTimes = {}
local CT = MM.ClearTimes

-- Samples beyond this stop moving the mean much, and capping n keeps a long
-- history from freezing the estimate against a player who has genuinely got
-- faster -- gear, level and group size all change.
local MAX_SAMPLES = 20

-- Below this, a "clear" is someone zoning in and straight back out; above it,
-- an afk. Neither is a measurement of how long the content takes.
local MIN_MINUTES, MAX_MINUTES = 2, 180

local function store()
	MM.cdb = MM.cdb or {}
	MM.cdb.clearTimes = MM.cdb.clearTimes or {}
	return MM.cdb.clearTimes
end

-- The learned average for an instance, or nil when nothing has been seen.
-- Returns minutes, sample count.
function CT.Get(name)
	if not name then return nil end
	local rec = store()[name:lower()]
	if not rec or not rec.mean then return nil end
	return rec.mean, rec.n or 0
end

-- Fold one observation into the mean.
function CT.Record(name, minutes)
	if not (name and minutes) then return end
	if minutes < MIN_MINUTES or minutes > MAX_MINUTES then return end
	local db = store()
	local key = name:lower()
	local rec = db[key]
	if not rec then
		db[key] = { mean = minutes, n = 1 }
		return db[key].mean, 1
	end
	local n = math.min(rec.n or 1, MAX_SAMPLES)
	-- The mean BEFORE this run is what "faster or slower" measures against.
	-- Comparing against the mean that already includes this run would drag the
	-- comparison toward the sample and understate every change.
	local was = rec.mean
	rec.mean = ((rec.mean * n) + minutes) / (n + 1)
	rec.n = n + 1
	return rec.mean, rec.n, was
end

------------------------------------------------------------
-- Watching for a clear
------------------------------------------------------------
-- The clock starts when you zone INTO an instance and stops when you zone out.
-- Not on boss kills: a mount can drop from trash, from the last boss, or from
-- a chest afterwards, and what the plan needs to know is how long the VISIT
-- takes -- door to door.
local inside, startedAt, instanceName

local function now()
	return GetTime and GetTime() or 0
end

local function check()
	local name, kind = GetInstanceInfo and GetInstanceInfo()
	local isInstance = kind == "party" or kind == "raid" or kind == "scenario"
	if isInstance and not inside then
		inside, startedAt, instanceName = true, now(), name
	elseif not isInstance and inside then
		inside = false
		if instanceName and startedAt then
			local minutes = (now() - startedAt) / 60
			local mean, n, was = CT.Record(instanceName, minutes)
			if mean and MM.Print then
				-- A minute either way is noise, not a trend. Below that the line
				-- would claim a direction on nothing, and a tracker that cries
				-- "faster!" over forty seconds stops being read at all.
				local trend = ""
				if was and n and n > 1 then
					local delta = was - minutes
					if delta >= 1 then
						trend = ("  |cff40d860%.0f min faster than your average.|r")
							:format(delta)
					elseif delta <= -1 then
						trend = ("  |cffff9a3c%.0f min slower than your average.|r")
							:format(-delta)
					else
						trend = "  |cff9a9a9aRight on your average.|r"
					end
				end
				MM:Print("Timed %s: %.0f min.%s This character now averages "
					.. "%.0f min over %d run%s.", instanceName, minutes,
					trend, mean, n, n == 1 and "" or "s")
			end
		end
		startedAt, instanceName = nil, nil
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:SetScript("OnEvent", function() pcall(check) end)

------------------------------------------------------------
-- Reporting
------------------------------------------------------------
function CT.Summary()
	local out, total = {}, 0
	for key, rec in pairs(store()) do
		total = total + 1
		out[#out + 1] = { name = key, mean = rec.mean, n = rec.n or 0 }
	end
	table.sort(out, function(a, b) return (b.n or 0) < (a.n or 0) end)
	return out, total
end

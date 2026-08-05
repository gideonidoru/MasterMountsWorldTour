-- Master Mounts: source validation against Blizzard's own strings.
--
-- The mount journal ships a source description for every mount --
-- C_MountJournal.GetMountInfoExtraByID returns it as its third value -- and it
-- is the most authoritative text available anywhere, because it comes from the
-- same database that decides what actually drops.
--
-- We already read it, but only for mounts the database does not know. Every
-- record we DO know was never checked against it, so a wrong boss or a wrong
-- instance could sit in the data indefinitely while the addon confidently sent
-- someone to the wrong place. The Tazavesh/Dornogal mix-up was exactly that,
-- and it was caught by a person reading a nav card rather than by any check.
--
-- WHY THE COMPARISON HAPPENS IN-GAME. The obvious approach is to dump 1,626
-- lines and diff them offline, but that is a wall of text to move by hand and
-- most of it agrees. Both strings are already here, so the disagreement is
-- computed here too and only the residue is printed. The output is the work
-- list, not the raw material.
--
-- WHAT "DISAGREEMENT" MEANS. Not string equality -- the two are written by
-- different people for different purposes ("Drops from So'leah in Tazavesh,
-- the Veiled Market" vs "Tazavesh, the Veiled Market"). What matters is
-- whether the SIGNIFICANT NOUNS in Blizzard's text appear anywhere in ours. A
-- boss name, an instance, a vendor, a zone. If Blizzard says Oribos and our
-- record never mentions Oribos, that is worth a human looking at; if the
-- wording differs but every proper noun is present, it is not.
local _, MM = ...

MM.SourceAudit = {}
local SA = MM.SourceAudit

-- Words that carry no identifying weight. Kept deliberately short: over-filter
-- and real terms vanish, under-filter and the score is noise. Anything here is
-- a word that appears in so many source strings that its presence proves
-- nothing about whether the two texts describe the same acquisition.
local STOP = {
	["the"]=1,["a"]=1,["an"]=1,["and"]=1,["or"]=1,["of"]=1,["in"]=1,["on"]=1,
	["from"]=1,["for"]=1,["to"]=1,["at"]=1,["by"]=1,["with"]=1,["is"]=1,["it"]=1,
	["drop"]=1,["drops"]=1,["dropped"]=1,["reward"]=1,["rewarded"]=1,["chance"]=1,
	["mount"]=1,["mounts"]=1,["this"]=1,["that"]=1,["you"]=1,["your"]=1,
	["can"]=1,["be"]=1,["are"]=1,["as"]=1,["also"]=1,["after"]=1,["during"]=1,
	["completing"]=1,["complete"]=1,["completed"]=1,["obtained"]=1,["obtain"]=1,
	["purchased"]=1,["purchase"]=1,["bought"]=1,["buy"]=1,["sold"]=1,["vendor"]=1,
	["achievement"]=1,["quest"]=1,["item"]=1,["level"]=1,["requires"]=1,
	["available"]=1,["only"]=1,["all"]=1,["any"]=1,["one"]=1,["two"]=1,
	-- STRUCTURAL LABELS. The journal writes "Vendor: X / Zone: Y / Cost: N".
	-- Those headings are formatting, not identity: every vendor entry contains
	-- "vendor" and "zone", so counting them rewards a record for agreeing about
	-- the shape of the sentence rather than about where the mount comes from.
	["zone"]=1,["zones"]=1,["cost"]=1,["faction"]=1,["category"]=1,["location"]=1,
	["renown"]=1,["difficulty"]=1,["treasure"]=1,["profession"]=1,["covenant"]=1,
	["source"]=1,["event"]=1,["world"]=1,["holiday"]=1,["feature"]=1,["class"]=1,
	["vendors"]=1,["trainer"]=1,["area"]=1,["discovery"]=1,["exalted"]=1,
	["revered"]=1,["honored"]=1,["friendly"]=1,["player"]=1,["season"]=1,
	["rated"]=1,["nrated"]=1,["arena"]=1,["battleground"]=1,["reward"]=1,
}

-- Significant tokens: 4+ letters, not a stopword. Apostrophes kept because
-- "So'leah" and "Ny'alotha" are exactly the words that matter most here.
--
-- MARKUP MUST GO FIRST, and the first version of this did not do it. The
-- journal's strings carry live WoW escapes -- |cffffd200 colour, |Hcurrency:
-- hyperlinks, |TInterface\Icons\...|t textures -- and a plain letter match
-- shreds them into words that look real: "cffffd", "tinterface", "hcurrency".
-- Worse, the |r terminator fuses onto the word after it, so Ardenweald became
-- "rardenweald" and stopped matching our perfectly correct "Ardenweald".
--
-- The effect was not subtle. "Drop: Humon'gozz / Zone: Ardenweald" against
-- "Drops from Humon'gozz in Ardenweald" scored ZERO, and 1,020 of 1,371
-- records were reported as disagreeing when most of them agree exactly.
--
-- Diagnostics.Plain already strips exactly this, for exactly this reason.
local function tokens(text)
	local out = {}
	if type(text) ~= "string" then return out end
	if MM.Diagnostics and MM.Diagnostics.Plain then
		text = MM.Diagnostics.Plain(text)
	end
	-- Belt and braces: Plain covers the display escapes, this catches any raw
	-- pipe sequence that reaches us before Diagnostics has loaded.
	text = text:gsub("|%a", " "):gsub("|", " ")
	for w in text:gmatch("[%a][%a']+") do
		local lw = w:lower()
		if #lw >= 4 and not STOP[lw] then out[lw] = true end
	end
	return out
end

-- Fraction of Blizzard's significant words that our source also mentions.
-- Returns the score and the words we are missing, because "0.4" is a grade and
-- "missing: oribos, tazavesh" is a next action.
function SA.Compare(blizzard, ours)
	local b = tokens(blizzard)
	local o = tokens(ours)
	local total, hit, missing = 0, 0, {}
	for w in pairs(b) do
		total = total + 1
		if o[w] then hit = hit + 1 else missing[#missing + 1] = w end
	end
	if total == 0 then return nil, missing end
	table.sort(missing)
	return hit / total, missing
end

------------------------------------------------------------
-- The scan
------------------------------------------------------------
-- Categories whose "source" is a storefront, a code or a dead entry. Blizzard's
-- text and ours will never line up and neither is wrong, so they are excluded
-- rather than reported as 237 permanent disagreements nobody will ever action.
local SKIP_CATEGORY = {
	STORE = true, TCG = true, PROMOTION = true, REMOVED = true,
}

SA.results = nil
SA.progress = nil

-- Chunked. 1,626 mounts each doing two tokenisations is not free, and the one
-- time this addon locked up the client it was a diagnostic that did all of its
-- work in a single frame. 150 per frame keeps it invisible.
local CHUNK = 150

function SA.Run(onDone)
	if not (MM.Scanner and MM.Scanner.mounts and #MM.Scanner.mounts > 0) then
		MM:Print("Collection has not been scanned yet — try again in a moment.")
		return
	end
	local list = MM.Scanner.mounts
	local i, out = 1, {}
	SA.progress = 0

	local function step()
		local stop = math.min(i + CHUNK - 1, #list)
		for n = i, stop do
			local entry = list[n]
			local rec = entry.rec
			local cat = rec and rec.category
			if rec and not rec.stub and not SKIP_CATEGORY[cat or ""] and entry.mountID then
				local ok, _, _, blizz = pcall(C_MountJournal.GetMountInfoExtraByID, entry.mountID)
				blizz = ok and blizz or nil
				if type(blizz) == "string" and blizz ~= "" then
					local score, missing = SA.Compare(blizz, rec.source)
					if score and score < 1 then
						out[#out + 1] = {
							name = entry.name, category = cat, score = score,
							missing = missing, blizz = blizz, ours = rec.source or "",
						}
					end
				end
			end
		end
		i = stop + 1
		SA.progress = math.floor(i / #list * 100)
		if i <= #list then
			C_Timer.After(0, step)
		else
			table.sort(out, function(a, b)
				local sa, sb = a.score or 0, b.score or 0
				if sa == sb then return (a.name or "") < (b.name or "") end
				return sa < sb
			end)
			SA.results = out
			if onDone then onDone(out) end
		end
	end
	step()
end

------------------------------------------------------------
-- Reporting
------------------------------------------------------------
-- Only the disagreements, worst first, in a form that pastes cleanly. The
-- threshold is a knob because the right cut is a judgement about how much
-- noise is worth reading, not a fact about the data.
local function report(threshold, limit)
	local out = SA.results or {}
	local shown = 0
	MM:Print("|cffffd84dSOURCE AUDIT|r  our record vs the journal's own text")
	MM:Print("   %d of %d records disagree to some degree; showing those under %d%%.",
		#out, MM.Scanner and #MM.Scanner.mounts or 0, math.floor(threshold * 100))
	MM:Print("   A low score means words Blizzard uses do not appear in our source.")
	MM:Print(" ")
	for _, r in ipairs(out) do
		if r.score < threshold and shown < limit then
			shown = shown + 1
			MM:Print("|cffff9a3c%s|r  (%s, %d%% match)", r.name, r.category or "?",
				math.floor(r.score * 100))
			MM:Print("     journal: %s", r.blizz)
			MM:Print("     ours   : %s", r.ours ~= "" and r.ours or "(none recorded)")
			if #r.missing > 0 then
				MM:Print("     missing: %s", table.concat(r.missing, ", "))
			end
		end
	end
	if shown == 0 then
		MM:Print("   Nothing under that threshold — every record names what the journal names.")
	else
		MM:Print(" ")
		MM:Print("   %d shown. Raise the threshold to see more: /mm sources 0.8", shown)
	end
end

MM:On("MM_SOURCES", function(arg)
	local threshold = tonumber(arg) or 0.5
	local limit = 60
	MM:Print("Comparing every record against the journal's own source text...")
	SA.Run(function() report(threshold, limit) end)
end)

-- Machine-readable, for pasting somewhere that will diff it properly. Same
-- data, one record per block, no colour codes.
MM:On("MM_SOURCES_EXPORT", function(arg)
	local threshold = tonumber(arg) or 0.5
	SA.Run(function(out)
		local lines = { "# Master Mounts source audit", "" }
		local n = 0
		for _, r in ipairs(out) do
			if r.score < threshold then
				n = n + 1
				lines[#lines + 1] = ("## %s [%s] %d%%"):format(
					r.name, r.category or "?", math.floor(r.score * 100))
				lines[#lines + 1] = "journal: " .. r.blizz
				lines[#lines + 1] = "ours   : " .. (r.ours ~= "" and r.ours or "(none)")
				lines[#lines + 1] = "missing: " .. table.concat(r.missing, ", ")
				lines[#lines + 1] = ""
			end
		end
		lines[#lines + 1] = ("# %d records below %d%%"):format(n, math.floor(threshold * 100))
		if MM.Diagnostics and MM.Diagnostics.ShowExport then
			MM.Diagnostics.ShowExport(table.concat(lines, "\n"), "Source audit")
		else
			for _, l in ipairs(lines) do print(l) end
		end
	end)
end)

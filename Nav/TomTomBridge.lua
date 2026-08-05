-- Master Mounts navigation dispatch: prefers TomTom's crazy-arrow when the
-- user has it (and wants it), otherwise drives our built-in arrow.
local _, MM = ...

MM.Nav = MM.Nav or {}
local Nav = MM.Nav

local tomtomUID

local function tomTomUsable()
	return MM.db and MM.db.useTomTom and _G.TomTom and _G.TomTom.AddWaypoint and true or false
end

function Nav.ClearWaypoint()
	if tomtomUID and _G.TomTom and _G.TomTom.RemoveWaypoint then
		pcall(_G.TomTom.RemoveWaypoint, _G.TomTom, tomtomUID)
	end
	tomtomUID = nil
	if MM.Arrow then MM.Arrow:Clear() end
end

function Nav.SetWaypoint(step)
	Nav.ClearWaypoint()
	if not step or not step.mapID then return end

	-- Cross-continent goals need our multi-step travel guidance, which
	-- TomTom's single crazy-arrow can't express — always use our arrow there.
	local playerContinent = select(1, MM.Util.PlayerWorldPos())
	if step.continent and playerContinent and step.continent ~= playerContinent then
		if MM.Arrow then MM.Arrow:SetTarget(step) end
		return
	end

	if tomTomUsable() then
		local ok, uid = pcall(_G.TomTom.AddWaypoint, _G.TomTom,
			step.mapID, step.x / 100, step.y / 100, {
				title = "Master Mounts: " .. (step.label or "goal"),
				from = "MasterMounts",
				persistent = false,
				crazy = true,
			})
		if ok and uid then
			tomtomUID = uid
			return
		end
	end

	-- fall back to the built-in arrow
	if MM.Arrow then MM.Arrow:SetTarget(step) end
end

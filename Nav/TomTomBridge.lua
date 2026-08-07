-- Master Mounts navigation dispatch: drives our built-in arrow, or hands the
-- waypoint to TomTom for anyone who asks for that.
--
-- TOMTOM IS OPT-IN, NOT THE DEFAULT. It used to be preferred whenever it was
-- installed, and that was the wrong call: TomTom has ONE crazy arrow and a
-- great many addons write to it. Whichever one wrote last owns the screen, so
-- a route could be quietly steered away mid-leg by something that had nothing
-- to do with mounts, and from the player's side Master Mounts simply looked
-- like it was pointing at the wrong thing. Our own arrow cannot be taken over
-- by anybody, so it is what ships on.
--
-- THE HANDOVER HAS TO WORK IN BOTH DIRECTIONS. Nothing used to re-run this
-- dispatch when the setting changed, so flipping it mid-route did nothing
-- visible until the next step: turning TomTom off left its waypoint standing
-- and never brought our arrow back, and turning it on left our arrow up while
-- TomTom got nothing. `Nav.Refresh` exists for that -- it tears both providers
-- down and rebuilds whichever one is now chosen, from the step we are actually
-- on. Which is why the step is REMEMBERED here rather than only passed
-- through: at the moment the setting flips, the caller that knows the step is
-- not the one doing the flipping.
local _, MM = ...

MM.Nav = MM.Nav or {}
local Nav = MM.Nav

local tomtomUID
local currentStep

local function tomTomUsable()
	return MM.db and MM.db.useTomTom and _G.TomTom and _G.TomTom.AddWaypoint and true or false
end

-- Give TomTom's waypoint back. `RemoveWaypoint(uid)` is TomTom's own documented
-- call and the uid is the one it handed us, so this is the right request rather
-- than a hopeful one -- but it is wrapped because a third-party addon is
-- allowed to be missing, be a different version, or have dropped the waypoint
-- already, and none of those may take the route down with them.
local function releaseTomTom()
	local tt = _G.TomTom
	if tomtomUID and tt and type(tt.RemoveWaypoint) == "function" then
		pcall(tt.RemoveWaypoint, tt, tomtomUID)
	end
	tomtomUID = nil
end

function Nav.ClearWaypoint()
	releaseTomTom()
	currentStep = nil
	if MM.Arrow then MM.Arrow:Clear() end
end

function Nav.SetWaypoint(step)
	Nav.ClearWaypoint()
	if not step or not step.mapID then return end
	currentStep = step

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

-- Re-dispatch the step we are on through whichever provider is chosen now.
-- Called when the TomTom setting is toggled, and safe to call at any other
-- time: with no step in flight it clears, which is already the correct state.
--
-- If TomTom declined to release its waypoint, this shows our arrow anyway. Two
-- arrows is a worse look than one but it is recoverable by the player looking
-- at it; showing nothing at all, on a route someone is mid-way through, is not.
function Nav.Refresh()
	local step = currentStep
	if not step then
		Nav.ClearWaypoint()
		return
	end
	Nav.SetWaypoint(step)
end

-- For diagnostics: which provider is actually driving right now, and is there
-- anything to drive. Reported rather than inferred from the setting, because
-- the setting is the request and this is the outcome -- they differ whenever
-- TomTom is switched on but absent, or the leg is cross-continent.
function Nav.Provider()
	if not currentStep then return "none" end
	return tomtomUID and "tomtom" or "builtin"
end

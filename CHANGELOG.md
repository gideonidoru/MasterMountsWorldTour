# Changelog

## 1.0.0 — unreleased

Everything below happened before first publish. The version stays 1.0.0
until it actually ships; the interim numbers were bookkeeping noise, not
releases anyone could have installed.

### 1.6.0

**The travel network was 91 disconnected islands.**

The 238 recorded connections are only the ones distance cannot derive -- portals,
boats, zeppelins. On their own the largest connected component was 29 nodes out
of 1,156, so almost every pair had no path and the network returned nothing on
every leg. The data was correct and the graph was useless.

Nodes close enough to fly between are now connected, priced by real distance --
which is what makes a portal reachable at all: fly to it, step through, fly on
from the far side. Same continent only, capped at 3,000 yards.

    before   132 nodes in graph ·  91 components · largest  29
    after   1135 nodes in graph ·  84 components · largest 563

Built lazily on the first route, never at login: 1,156 position lookups once per
node, not per pair.

`/mm routertest` now reports recorded and generated connections separately.

### 1.5.0

**The measured flight times were never actually being used.** `/mm routertest`
reported `direct 8 · taxi 0 · network 0` -- eight legs, zero uses -- which is
what loaded-but-inert looks like from outside.

Two naming faults, both mine:

- **Bare versus zone-qualified names.** Flight-point data calls a master
  "Darkbreak Cove"; the duration graph calls it "Darkbreak Cove, Vashj'ir".
  Every lookup missed, on every leg. Names are now normalised through the index,
  which already held both forms.
- **Contested bare names went to the wrong node.** Several places exist twice --
  "Astranaar" and "Astranaar, Ashenvale" -- and one of the pair is a stub with
  no edges. First-seen won, so routes through it returned "no path" while the
  real node sat there fully connected. The better-connected node now wins,
  because that is exactly the property that matters.

Also removed a duplicate flight-point dataset I had built without noticing that
`Nav/FlightPointData.lua` already shipped the same 813 points.

### 1.4.0

**Chat discipline, and a Timewalking mount that was telling you to wait for the
wrong week.**

- **Infinite Timereaver is no longer labelled "Warlords of Draenor".** It drops
  from any Timewalking boss in any era; its record said so in prose but carried
  no `anyEra` flag, so the era logic fell back to the expansion it was added in.
  Waiting for the wrong era is a month of not farming something available the
  whole time.
- **Three copies of the era rule are now one.** Router.lua checked for "every
  era" and missed "any era"; Availability.lua handled both; Timewalking.lua had
  a third. They disagreed. All three now call one resolver.
- **The session dropdown no longer offers "End session".** It sets a length, it
  never starts anything — offering to end implies it started. "No limit" is the
  off state.
- **Chat is much quieter.** Choosing a session length is silent: the dropdown
  reads the length and the plan list already shows only what fits, so two more
  lines narrated what you were looking at. A route resume prints one line
  instead of three. The MountsRarity notice is said once, ever, not at every
  login.

### 1.3.0

- **`/mm routertest` is now verbose about travel data.** It answers the three
  questions that fail differently: did the data load, is it reachable by name,
  and is it actually being USED. The last one is the one nobody checks -- a
  dataset can be loaded, valid, and never consulted, which looks identical to
  working. It prices real legs from your current route three ways (direct /
  taxi / network) and marks which one the router will pick.
- `TX.TravelMinutes` takes a `skipNetwork` flag so the diagnostic can measure
  the taxi graph alone. Without it the comparison columns contain each other and
  cannot show which dataset is doing the work.

### 1.2.0

Completes the travel-data work in 1.1.0 after a full re-audit of both sources.

- **Flight data was under-parsed.** Nodes with NEGATIVE ids (Nighthaven and ten
  others) were never seen at all -- the pattern could not match a minus sign --
  and ten duplicate node ids overwrote each other instead of merging. Now
  795 nodes and 4,068 hops, with every one of the 4,157 entries in the source
  accounted for: 4,068 captured, 84 zero-valued, 1 duplicate merged, 4 outside
  any block.
- **No network edge is free.** `fly` and `flight` edges had no stated cost, and
  a zero-weight edge inside a shortest-path search is teleportation -- the
  router would chain them across the world at no charge. They are now priced
  from the real distance between endpoints, with a non-zero floor.
- **Two new self-tests** assert both datasets loaded, that every flight hop is
  reachable by name, and that no edge is priced at zero. All three failures
  above were silent; none of them errored.

### 1.1.0

**Routing now runs on measured times instead of straight-line guesses.**

- **Measured flight durations.** 785 flight masters, 4,054 hops, real observed
  seconds each. A flight follows a scripted path with turns, altitude and a
  takeoff, so distance-over-speed was wrong in both directions and never by a
  consistent factor. Multi-hop routes use them too, not just direct flights.
- **The portal / ship / zeppelin / tram network.** 1,156 endpoints with real
  coordinates and 238 connections. These legs are not distance at all — a portal
  is fifteen seconds and half a world — and were previously priced as a flat hub
  charge or not modelled as connections at all.
- The two compete: whichever is genuinely faster wins, and the network returns
  nothing when it cannot connect two points, so it only ever replaces an answer
  with a cheaper one.
- `/mm travel` now opens by stating what both datasets cover, so a suspicious
  route can be diagnosed without guessing which half failed to load.

Durations that the source states are used as given; the rest take a per-method
default that is labelled ASSUMED, so the time model keeps reporting measured
versus assumed honestly.

## 1.0.0

First release.

**Planning**

- 1,608 mounts catalogued with source, drop rate, lockout and prerequisites
- Builds a route, not a list — ordered by travel time and effort, pricing every
  portal, ship, flight path and teleport item you own
- Groups mounts that share a stop, so five Island Expedition mounts are one visit
- **Pick the time you actually have** and the plan is constrained to fit it
- Faction, class, profession, reputation and lockout gates all checked, so it
  won't send you somewhere nothing can happen

**Rares**

- Watches the rares that drop mounts you're still missing — not every rare in
  the game, just yours
- Triggered off vignette data, so you hear about it while you can still get there
- Shows the model, the drop, the distance and a target button; once per spawn
- Rares you already have the mount from never fire

**Trust**

- Every estimate says whether it was measured or assumed
- Unknowns are costed pessimistically, so a guess can never outrank real work
- `/mm report` shows everything it knows and everything it doesn't
- `/mm contribute` exports the gaps a player standing in the right place could
  actually answer, and imports someone else's back

**Also**

- Warband-aware reputation, currency and professions
- Attempts tracked account-wide, with no implied pity timer
- Nav arrow, map pins, rare alerts, TomTom and MountsRarity support

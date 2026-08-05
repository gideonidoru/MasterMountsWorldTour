# Master Mounts – World Tour

[![CurseForge](https://img.shields.io/badge/CurseForge-Master%20Mounts%20World%20Tour-f16436)](https://www.curseforge.com/wow/addons/master-mounts-world-tour)

**Download:** [CurseForge](https://www.curseforge.com/wow/addons/master-mounts-world-tour)

A mount-collection addon for World of Warcraft retail that answers the question
a checklist can't: **what should I actually do tonight?**

It catalogues 1,608 mounts, works out which ones you can make progress on right
now, and plans a route through them — ordered by real travel time, using your
teleports, hearthstones and portals.

## What it does

- **Routes, doesn't list.** Stops are ordered by travel cost, not alphabetically.
  It knows a Hearthstone to Valdrakken beats a 3,500-yard flight, and that five
  Island Expedition mounts are one visit rather than five.
- **Fits your session.** Tell it you have 45 minutes and it gives you a plan
  that fits in 45 minutes.
- **Tracks attempts** account-wide, and never implies a pity timer, because
  there isn't one.
- **Explains itself.** Every goal can say why it landed where it did —
  preference, shared stop, or travel time.
- Nav arrow, map pins, rare alerts, TomTom support, ElvUI theming.

## The unusual part

**The addon knows what it doesn't know, and says so.**

Around 40% of its time estimates are assumptions rather than measurements —
prices only readable while standing at a vendor, drop rates nobody has ever
observed, achievements it can only read as prose. Rather than hiding that behind
a confident number:

- every estimate is tagged `measured` or `assumed`, and `/mm timemodel` shows
  the split
- unknowns are costed **pessimistically**, so something it can't price can never
  outrank real work — the ORDER stays sound even where the TOTAL is an upper bound
- `/mm score` computes a scorecard from live state, with nothing asserted, and
  itemises what it's missing

Some things genuinely cannot be known by anyone: soloability of legacy raids
depends on class, gear and patch and no API exposes it; a drop rate nobody has
observed does not exist to look up. Those are recorded as unknown rather than
guessed. Inventing them would make the numbers look better and be worth less.

## Commands

| Command | What it does |
|---|---|
| `/mm` | open the main window |
| `/mm route` | start / stop the route |
| `/mm session 45` | plan for a 45-minute sitting |
| `/mm report` | full diagnostic, into a copyable window |
| `/mm score` | the scorecard, computed live |
| `/mm timemodel` | measured vs assumed split |
| `/mm contribute` | export the gaps a player could answer |
| `/mm resolve` | resolve ids from the client |

## Helping it get better

`/mm contribute` exports the gaps that a player standing in the right place
could actually answer — a vendor price, a coordinate, whether a legacy raid
soloed. Import merges someone else's export back in.

Some of the unmatched names may be typos in our data rather than platform
limits; that export is how they get found.

## Installation

Drop the `MasterMountsWorldTour` folder into `Interface/AddOns/`. The folder must
keep that exact name — the `.toc` and the art paths are derived from it.

Retail only, tested against 12.0.7 (Midnight).

## License

[MIT](LICENSE).

Bundled libraries under `Libs/` are third-party and carry their own licenses:
LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0.

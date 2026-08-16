# Audit: reviewed disagreements

Every entry below was read individually against Wowhead's item tooltip and
confirmed **correct as we have it**. The Wowhead guide buckets mounts by how a
collector *browses* them; we categorise by what the player actually has to *do*.
Where those differ, ours is the more actionable of the two and the other fact is
preserved as a condition.

A re-run of the audit should suppress these rather than re-flagging them. If one
changes in game, delete its line here so it surfaces again.

| Mount | Guide says | We say | Why ours is right |
|---|---|---|---|
| Conqueror's Scythemaw | achiev | PVP | Achievement is *Conqueror of Azeroth* — rated PvP wins. PVP is the activity. |
| Arcanist's Manasaber | achiev | QUEST | Reward from *Fate of the Nightborne*, the end of the Suramar questline. |
| Feldrake | achiev | TCG | Tomb of the Forgotten TCG loot card. Not an achievement at all. |
| Blacksteel Battleboar | achiev | VENDOR | Guild vendor, 4,000g; the guild achievement is a condition on the record. |
| Bloodflank Charger | achiev | VENDOR | The Honorbound quartermaster; achievement is a condition. |
| Dark Phoenix | achiev | VENDOR | Guild vendor, 3,000g; guild achievement is a condition. |
| Grand Gryphon | achiev | VENDOR | Sold by Vasarin Redmorn, Isle of Thunder. Corrected from QUEST in this audit. |
| Grand Wyvern | achiev | VENDOR | Sold by Hiren Loresong, Isle of Thunder. Corrected from QUEST in this audit. |
| Heavenly Crimson Cloud Serpent | achiev | VENDOR | Black Market AH (Madam Goya). |
| Ironclad Frostclaw | achiev | VENDOR | 7th Legion quartermaster; achievement is a condition. |
| Nazjatar Blood Serpent | drops | PUZZLE | Collect 20 Abyssal Fragments and summon — no mob drops the mount. |
| White Polar Bear | drops | QUEST | Chance from Hyldnir Spoils, the Brunnhildar daily's reward bag. |
| Green Proto-Drake | drops | REP | From the Mysterious Egg, which is *bought* from The Oracles at Revered. |
| Crimson Water Strider | profs | GARRISON | Garrison Fishing Shack via Nat Pagle, not a profession recipe. |
| Brinedeep Bottom-Feeder | profs | VENDOR | Bought for 100 Drowned Mana from Conjurer Margoss. |
| Bruce | quests | ACHIEVEMENT | Brawler's Guild reward. |
| Bone-White Primal Raptor | quests | CURRENCY | 9,999 Giant Dinosaur Bones turned in to Ku'ma. |
| Saltwater Seahorse | quests | CURRENCY | 500 Seafarer's Dubloons. |
| Siltwing Albatross | quests | CURRENCY | 1,000 Seafarer's Dubloons. |
| Risen Mare | quests | ZONEDROP | Island Expedition reward. Corrected from DROP in this audit. |
| Stonehide Elderhorn | quests | ZONEDROP | Island Expedition reward. Corrected from DROP in this audit. |
| Twilight Avenger | quests | ZONEDROP | Island Expedition reward. Corrected from DROP in this audit. |
| Prestigious War Steed | quests | PVP | *Free For All, More For Me* — Broken Isles PvP world quests. |
| Prestigious War Wolf | quests | PVP | Same achievement, other faction. |
| Voidtalon of the Dark Star | quests | RARE | A rare-spawning portal you click; no quest involved. |
| Winterspring Frostsaber | quests | REP | The Wintersaber Trainers rep grind. |
| Deathtusk Felboar | rep | RARE | Tanaan Jungle rare content, not a reputation purchase. |
| Black Stallion | rep | REMOVED | Removed from vendors in an early patch. |
| Rocktusk Battleboar | vendor | GARRISON | Garrison Trading Post at level 3. |

## Resolved by correction, not by exception

- **Goldenmane** — we had "Sold by the Storm's Wake quartermaster at Exalted",
  which sent players to grind a reputation for a mount no vendor sells. Wowhead's
  drop table shows 31 Kul Tiran mob types across Stormsong Valley, Tiragarde
  Sound and Drustvar, pooled 1,007 drops in 5,779,106 kills. Now ZONEDROP with
  `dropRate = 0.0174`.

---

# The Littlest Mountain audit (2026-08-04)

Second guide, different axis. It is organised by expansion and continent rather
than acquisition method, so it audits **coverage** and **expansion assignment**.

**Coverage: 785 guide mounts, 779 already ours (533 by spellID, 246 by name),
6 absent.** Five were real and were added (`Data/Data_83_Littlest.lua`). The
sixth was not a mount at all — see below.

**Expansion assignment: 467 checkable, 439 agree, 28 differ — none an error.**
The guide's sections describe *where you travel*, not *which expansion added the
mount*. Its first leg, "Easing through Kalimdor & Eastern Kingdoms", is where a
low-level character buys racial mounts, so TBC-era Hawkstriders and Elekks
(expansion 1) and Cataclysm-era Goblin Trikes and Mountain Horses (expansion 3)
all appear under it. Our expansion field means the patch that introduced the
mount, which is what the ranker needs for its legacy/current split. Both are
right about different things.

Individually checked and left alone:

| Mount | Ours | Guide leg | Why ours is right |
|---|---|---|---|
| Hawkstriders, Elekks (11 mounts) | 1 | Kalimdor & EK | Blood elf / draenei racial mounts, added in TBC, bought on the old continents. |
| Goblin Trike, Goblin Turbo-Trike, Mountain Horse, Swift Mountain Horse | 3 | Kalimdor & EK | Goblin and worgen racial mounts, added in Cataclysm. |
| Swift Blue/Green/Purple Gryphon, Swift Green/Purple Wind Rider | 1 | Kalimdor & EK, Northrend | TBC flying mounts, sold in the old-world capitals. |
| Hearthsteed | 4 | Kalimdor & EK | Hearthstone cross-promotion, 2014. |
| Darkmoon Dirigible | 7 | Kalimdor & EK | Item 153485 is BfA-era; the Faire is simply reachable early. |
| Riding Turtle | 0 | Draenor | Original TCG loot card, not Draenor content. |

## Not a mount

`Gift of the Holy Keepers` (item 142224) is the **container** that grants the
Legion Priest class mount, which we already hold as "High Priest's Lightsworn
Seeker" (spell 229377). Adding it would have created a phantom entry nobody can
ever collect. An item in a mount guide is not necessarily a mount — check that
the tooltip declares a Mount *and* teaches a non-riding spell.

-- MasterMounts: rare NAMES for mounts the alert could not previously match.
-- The rare alert matches a live vignette against a record's npc.name (or
-- poolRares). A mount with neither can never fire an alert, however badly
-- the player wants it -- so coverage was capped at the ~159 records that
-- happened to name their NPC. These come from HandyNotes' rare tables,
-- joined on the mount name, and only fill records that had NEITHER field.
local _, MM = ...

MM.OverrideMount("Alunira", { npc = { name = "Alunira" } })
MM.OverrideMount("Ascended Skymane", { npc = { name = "The Ascended Council" } })
MM.OverrideMount("Cobalt Shalewing", { npc = { name = "Karokta" } })
MM.OverrideMount("Loyal Gorger", { npc = { name = "Worldedge Gorger" } })
MM.OverrideMount("Maddened Chaosrunner", { npc = { name = "Wrangler Kravos" } })
MM.OverrideMount("Zenet Hatchling", { npc = { name = "Zenet Avis" } })

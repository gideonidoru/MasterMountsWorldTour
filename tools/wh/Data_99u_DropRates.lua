-- MasterMounts: observed drop rates, from Wowhead's reported counts.
--
-- These records were ranked on an assumed 1%, which is not a measurement
-- and was wrong in BOTH directions -- Abyss Worm is 0.22%, others 2.5%.
-- A 4x error in either direction reorders the plan, so this changed the
-- advice and not just the totals.
--
-- `dropObserved` keeps the sample with the rate. 222/99271 is a
-- measurement; 3/12 is a rumour that happens to divide. Anything under
-- 200 observations is left at the assumption rather than dressed up.
--
-- Every source Wowhead reports for an item is SUMMED -- `sources` says
-- how many. The first pass took whichever source was listed first, so
-- Grand Black War Mammoth was 576/69331 from Archavon alone while four
-- other bosses and 202,000 further kills went unread.
--
-- Rates move: these are rolling observations, not constants, and a
-- re-run will not reproduce an older file exactly.
local _, MM = ...

MM.OverrideMount("Abyss Worm", { dropRate = 0.224, dropObserved = { count = 222, outOf = 99271 } }) -- item 143643
MM.OverrideMount("Aerial Unit R-21/X", { dropRate = 2.509, dropObserved = { count = 519, outOf = 20687 } }) -- item 168830
MM.OverrideMount("Anu'relos, Flame's Guidance", { dropRate = 0.626, dropObserved = { count = 68, outOf = 10867 } }) -- item 210061
MM.OverrideMount("Armored Bonehoof Tauralus", { dropRate = 0.477, dropObserved = { count = 186, outOf = 39001 } }) -- item 181815
MM.OverrideMount("Armored Razzashi Raptor", { dropRate = 0.685, dropObserved = { count = 2116, outOf = 308873 } }) -- item 68823
MM.OverrideMount("Ashes of Al'ar", { dropRate = 1.699, dropObserved = { count = 3179, outOf = 187121 } }) -- item 32458
MM.OverrideMount("Astral Cloud Serpent", { dropRate = 3.97, dropObserved = { count = 2174, outOf = 54763 } }) -- item 87777
MM.OverrideMount("Azure Drake", { dropRate = 2.425, dropObserved = { count = 1990, outOf = 82062 } }) -- item 43952
MM.OverrideMount("Battle-Bound Warhound", { dropRate = 0.5, dropObserved = { count = 476, outOf = 95124 } }) -- item 184062
MM.OverrideMount("Blazing Drake", { dropRate = 0.938, dropObserved = { count = 844, outOf = 89988 } }) -- item 77067
MM.OverrideMount("Bloodgorged Hunter", { dropRate = 1.337, dropObserved = { count = 33, outOf = 2468 } }) -- item 166468
MM.OverrideMount("Blue Drake", { dropRate = 0.229, dropObserved = { count = 417, outOf = 181776 } }) -- item 43953
MM.OverrideMount("Bonehoof Tauralus", { dropRate = 0.62, dropObserved = { count = 298, outOf = 48033 } }) -- item 182075
MM.OverrideMount("Cobalt Primordial Direhorn", { dropRate = 0.388, dropObserved = { count = 149, outOf = 38360 } }) -- item 94228
MM.OverrideMount("Cobalt Shalewing", { dropRate = 0.82, dropObserved = { count = 217, outOf = 26461 } }) -- item 205203
MM.OverrideMount("Colossal Plaguespew Mawrat", { dropRate = 25.183, dropObserved = { count = 310, outOf = 1231 } }) -- item 190765
MM.OverrideMount("Craghorn Chasm-Leaper", { dropRate = 3.444, dropObserved = { count = 85, outOf = 2468 } }) -- item 163583
MM.OverrideMount("Crimson Shardhide", { dropRate = 2.0, dropObserved = { count = 847, outOf = 42344 } }) -- item 186645
MM.OverrideMount("Deepstar Aurelid", { dropRate = 4.594, dropObserved = { count = 619, outOf = 13473 } }) -- item 187676
MM.OverrideMount("Drake of the North Wind", { dropRate = 0.771, dropObserved = { count = 1073, outOf = 139155, sources = 1 } }) -- item 63040
MM.OverrideMount("Drake of the South Wind", { dropRate = 1.954, dropObserved = { count = 1398, outOf = 71540 } }) -- item 63041
MM.OverrideMount("Endmire Flyer", { dropRate = 0.876, dropObserved = { count = 371, outOf = 42340 } }) -- item 180582
MM.OverrideMount("Experiment 12-B", { dropRate = 1.151, dropObserved = { count = 1271, outOf = 110407 } }) -- item 78919
MM.OverrideMount("Fallen Charger", { dropRate = 10.64, dropObserved = { count = 918, outOf = 8628 } }) -- item 186659
MM.OverrideMount("Felblaze Infernal", { dropRate = 0.436, dropObserved = { count = 168, outOf = 38537, sources = 1 } }) -- item 137574
MM.OverrideMount("Felsteel Annihilator", { dropRate = 3.52, dropObserved = { count = 2243, outOf = 63714 } }) -- item 123890
MM.OverrideMount("Fiery Warhorse", { dropRate = 1.101, dropObserved = { count = 3820, outOf = 346946 } }) -- item 30480
MM.OverrideMount("Flametalon of Alysrazor", { dropRate = 2.074, dropObserved = { count = 2643, outOf = 127445 } }) -- item 71665
MM.OverrideMount("Garn Steelmaw", { dropRate = 0.81, dropObserved = { count = 652, outOf = 80495 } }) -- item 116779
MM.OverrideMount("Garnet Razorwing", { dropRate = 2.614, dropObserved = { count = 475, outOf = 18171 } }) -- item 186652
MM.OverrideMount("Giant Coldsnout", { dropRate = 0.744, dropObserved = { count = 599, outOf = 80495 } }) -- item 116673
MM.OverrideMount("Glacial Tidestorm", { dropRate = 0.66, dropObserved = { count = 303, outOf = 45926 } }) -- item 166705
MM.OverrideMount("Grand Black War Mammoth", { dropRate = 0.731, dropObserved = { count = 1986, outOf = 271591, sources = 5 } }) -- item 44083
MM.OverrideMount("Heavenly Onyx Cloud Serpent", { dropRate = 0.275, dropObserved = { count = 240, outOf = 87230 } }) -- item 87771
MM.OverrideMount("Hellfire Infernal", { dropRate = 8.026, dropObserved = { count = 3093, outOf = 38537 } }) -- item 137575
MM.OverrideMount("Hopecrusher Gargon", { dropRate = 1.488, dropObserved = { count = 417, outOf = 28017 } }) -- item 180581
MM.OverrideMount("Horrid Dredwing", { dropRate = 2.122, dropObserved = { count = 1429, outOf = 67332 } }) -- item 180461
MM.OverrideMount("Invincible", { dropRate = 0.773, dropObserved = { count = 2054, outOf = 265761 } }) -- item 50818
MM.OverrideMount("Ironhoof Destroyer", { dropRate = 2.233, dropObserved = { count = 2730, outOf = 122246 } }) -- item 116660
MM.OverrideMount("Island Thunderscale", { dropRate = 9.151, dropObserved = { count = 152, outOf = 1661 } }) -- item 166467
MM.OverrideMount("Kor'kron Juggernaut", { dropRate = 0.894, dropObserved = { count = 856, outOf = 95768 } }) -- item 104253
MM.OverrideMount("Life-Binder's Handmaiden", { dropRate = 1.217, dropObserved = { count = 1095, outOf = 89988 } }) -- item 77069
MM.OverrideMount("Malevolent Drone", { dropRate = 1.22, dropObserved = { count = 336, outOf = 27543 } }) -- item 174769
MM.OverrideMount("Marrowfang", { dropRate = 0.452, dropObserved = { count = 226, outOf = 49948 } }) -- item 181819
MM.OverrideMount("Midnight", { dropRate = 0.942, dropObserved = { count = 1038, outOf = 110237 } }) -- item 142236
MM.OverrideMount("Mimiron's Head", { dropRate = 0.983, dropObserved = { count = 24, outOf = 2442, sources = 1 } }) -- item 45693
MM.OverrideMount("Mollie", { dropRate = 6.511, dropObserved = { count = 128, outOf = 1966 } }) -- item 174842
MM.OverrideMount("Noble Flying Carpet", { dropRate = 3.981, dropObserved = { count = 1850, outOf = 46471 } }) -- item 212599
MM.OverrideMount("Ny'alotha Allseer", { dropRate = 0.682, dropObserved = { count = 106, outOf = 15536 } }) -- item 174872
MM.OverrideMount("Onyxian Drake", { dropRate = 1.454, dropObserved = { count = 1220, outOf = 83927 } }) -- item 49636
MM.OverrideMount("Prototype A.S.M.R.", { dropRate = 0.57, dropObserved = { count = 111, outOf = 19459 } }) -- item 236960
MM.OverrideMount("Pureblood Fire Hawk", { dropRate = 1.691, dropObserved = { count = 549, outOf = 32471 } }) -- item 69224
MM.OverrideMount("Qinsho's Eternal Hound", { dropRate = 7.539, dropObserved = { count = 91, outOf = 1207 } }) -- item 163582
MM.OverrideMount("Red Qiraji Battle Tank", { dropRate = 1.007, dropObserved = { count = 37681, outOf = 3740865, sources = 10 } }) -- item 21321
MM.OverrideMount("Risen Mare", { dropRate = 12.07, dropObserved = { count = 165, outOf = 1367 } }) -- item 166466
MM.OverrideMount("Rivendare's Deathcharger", { dropRate = 0.866, dropObserved = { count = 1837, outOf = 212124 } }) -- item 13335
MM.OverrideMount("Sanctum Gloomcharger", { dropRate = 0.288, dropObserved = { count = 150, outOf = 52089 } }) -- item 186656
MM.OverrideMount("Shackled Ur'zul", { dropRate = 0.787, dropObserved = { count = 362, outOf = 46005 } }) -- item 152789
MM.OverrideMount("Smoky Direwolf", { dropRate = 1.004, dropObserved = { count = 808, outOf = 80495 } }) -- item 116786
MM.OverrideMount("Son of Galleon", { dropRate = 0.256, dropObserved = { count = 162, outOf = 63299 } }) -- item 89783
MM.OverrideMount("Squawks", { dropRate = 4.538, dropObserved = { count = 112, outOf = 2468 } }) -- item 163586
MM.OverrideMount("Stonehide Elderhorn", { dropRate = 1.459, dropObserved = { count = 36, outOf = 2468 } }) -- item 166470
MM.OverrideMount("Surf Jelly", { dropRate = 0.166, dropObserved = { count = 2, outOf = 1207 } }) -- item 163585
MM.OverrideMount("Swift Zulian Panther", { dropRate = 0.908, dropObserved = { count = 2593, outOf = 285605 } }) -- item 68824
MM.OverrideMount("Thundering Cobalt Cloud Serpent", { dropRate = 0.333, dropObserved = { count = 165, outOf = 49516 } }) -- item 95057
MM.OverrideMount("Thundering Onyx Cloud Serpent", { dropRate = 0.893, dropObserved = { count = 681, outOf = 76254 } }) -- item 104269
MM.OverrideMount("Twilight Avenger", { dropRate = 6.24, dropObserved = { count = 154, outOf = 2468 } }) -- item 163584
MM.OverrideMount("Vengeance", { dropRate = 0.478, dropObserved = { count = 175, outOf = 36607 } }) -- item 186642
MM.OverrideMount("Wild Glimmerfur Prowler", { dropRate = 1.074, dropObserved = { count = 270, outOf = 25143 } }) -- item 180730
MM.OverrideMount("Zereth Overseer", { dropRate = 0.574, dropObserved = { count = 87, outOf = 15151 } }) -- item 190768
MM.OverrideMount("Blue Qiraji Battle Tank", { dropRate = 8.647, dropObserved = { count = 323463, outOf = 3740865, sources = 10 } }) -- item 21218
MM.OverrideMount("Green Qiraji Battle Tank", { dropRate = 8.894, dropObserved = { count = 332705, outOf = 3740865, sources = 10 } }) -- item 21323
MM.OverrideMount("Yellow Qiraji Battle Tank", { dropRate = 8.995, dropObserved = { count = 336479, outOf = 3740865, sources = 10 } }) -- item 21324
MM.OverrideMount("Illidari Doomhawk", { dropRate = 11.537, dropObserved = { count = 1678, outOf = 14545, sources = 1 } }) -- item 186469
MM.OverrideMount("Ol' Mole Rufus", { dropRate = 5.984, dropObserved = { count = 131, outOf = 2189, sources = 1 } }) -- item 223501

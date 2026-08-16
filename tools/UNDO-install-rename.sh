#!/bin/bash
# Reverses the rename I should not have run inside your WoW install.
# Run it yourself, with WoW closed, ONLY if you want the old names back.
#
# What it undoes, exactly:
#   Interface/AddOns/MasterMountsWorldTour        -> MasterMounts
#   that folder's MasterMountsWorldTour.toc       -> MasterMounts.toc
#   every SavedVariables MasterMountsWorldTour.lua -> MasterMounts.lua
#     (account-wide + Scrann, Indrik, Lisko, Kaeleth, Muarn, plus .bak files)
#
# You probably do NOT want this: the new names match the addon's real folder
# name, and reverting means the shipped .toc no longer matches the folder.
# It exists so the change is reversible by you, not so you have to run it.
set -e
W="/Applications/World of Warcraft/_retail_"
if pgrep -x "World of Warcraft" >/dev/null; then
  echo "World of Warcraft is running. Quit it completely, then re-run."; exit 1
fi
T="$W/Interface/AddOns/MasterMountsWorldTour"
[ -f "$T/MasterMountsWorldTour.toc" ] && mv "$T/MasterMountsWorldTour.toc" "$T/MasterMounts.toc" \
  && echo "toc          -> MasterMounts.toc"
[ -d "$T" ] && mv "$T" "$W/Interface/AddOns/MasterMounts" \
  && echo "addon folder -> MasterMounts"
find "$W/WTF" -name "MasterMountsWorldTour.lua" -print0 | while IFS= read -r -d '' f; do
  mv "$f" "${f%/*}/MasterMounts.lua"; echo "saved vars   -> ${f%/*}/MasterMounts.lua"
done
find "$W/WTF" -name "MasterMountsWorldTour.lua.bak" -print0 | while IFS= read -r -d '' f; do
  mv "$f" "${f%/*}/MasterMounts.lua.bak"
done
echo "reverted."

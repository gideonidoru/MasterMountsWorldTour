#!/bin/bash
# Rebuild dist, then mirror it into the git repo.
#
# The repo canNOT live inside dist/ -- build_dist.sh starts with `rm -rf dist`
# and would delete .git with it. So the repo is a sibling directory and this
# copies into it, deleting files that no longer ship.
set -e
cd "$(dirname "$0")/.."
./tools/build_dist.sh
REPO="$HOME/Downloads/MasterMountsWorldTour-release"
[ -d "$REPO/.git" ] || { echo "No git repo at $REPO"; exit 1; }
# --delete so a file dropped from the .toc also leaves the repo
# Anything the repo owns but the addon does not ship MUST be excluded, or
# --delete removes it. CHANGELOG.md was lost exactly this way once.
rsync -a --delete \
      --exclude '.git' --exclude '.gitignore' \
      --exclude 'README.md' --exclude 'LICENSE' --exclude 'CHANGELOG.md' \
      --exclude 'NOTICE' --exclude 'HANDOFF.md' --exclude 'tools' \
      dist/MasterMountsWorldTour/ "$REPO/"

# THE BUILD TOOLS AND THE HANDOFF GO IN TOO, from source rather than from dist.
#
# They are not shipped -- build_dist copies only what the .toc names, so they
# cannot reach a download -- but "not shipped" had been quietly treated as "not
# worth keeping", and they lived in exactly one place on one disk with no
# history. audit.py is the largest single piece of reasoning in this project
# and every rule in it was written to catch something that had already gone
# wrong once. Losing it would cost more than losing the addon.
rsync -a --delete tools/ "$REPO/tools/"
cp HANDOFF.md "$REPO/HANDOFF.md"
echo "synced -> $REPO (addon from dist; tools/ and HANDOFF.md from source)"
cd "$REPO" && git status --short | head -20

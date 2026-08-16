#!/bin/bash
# Rebuild Data/Mounts.lua from the layered sources -- SAFELY.
#
# `lua tools/flatten_data.lua > Data/Mounts.lua` looks harmless and is not: the
# shell truncates Data/Mounts.lua BEFORE lua runs, so if the flattener throws --
# a syntax error in a new layer, a missing ORDER.txt entry -- the database is
# left empty and the failure is silent. The next tool to read it finds zero
# records and reports zero matches, which reads like a data problem rather than
# a build one.
#
# Build to a temp file, verify it parses, and only then move it into place.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -t mm_flat)"
trap 'rm -f "$TMP"' EXIT

lua tools/flatten_data.lua > "$TMP"
[ -s "$TMP" ] || { echo "flatten produced an EMPTY file -- refusing to install it" >&2; exit 1; }
luac -p "$TMP" || { echo "flatten produced a file that does not parse -- not installing" >&2; exit 1; }

mv "$TMP" Data/Mounts.lua
trap - EXIT
lua tools/verify_flatten.lua | tail -1

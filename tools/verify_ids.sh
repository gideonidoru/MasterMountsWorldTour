#!/bin/bash
# Verify every spellID in the database against Wowhead.
#
# Direction matters: we check ID -> name, which is the SAFE direction. A wrong
# ID silently maps a mount onto a different one at load time (it builds
# MM.DBBySpell), so a mismatch here is a real bug, not a cosmetic one.
#
# Usage: tools/verify_ids.sh [data_dir]   (default: ./Data)
set -u
DATA="${1:-$(dirname "$0")/../Data}"
UA="Mozilla/5.0"

grep -ho 'name = "[^"]*"[^\n]*spellID = [0-9]*\|spellID = [0-9]*[^\n]*name = "[^"]*"' "$DATA"/Data_[01]*.lua 2>/dev/null \
  | sed -E 's/.*name = "([^"]+)".*spellID = ([0-9]+).*/\2\t\1/; t; s/.*spellID = ([0-9]+).*name = "([^"]+)".*/\1\t\2/' \
  | sort -u > /tmp/mm_pairs.tsv

total=$(wc -l < /tmp/mm_pairs.tsv | tr -d ' ')
echo "Verifying $total spellIDs against Wowhead..."
ok=0; bad=0; fail=0
while IFS=$'\t' read -r sid name; do
  wh=$(curl -sL -A "$UA" --max-time 15 "https://www.wowhead.com/spell=$sid&xml" \
       | grep -o '<title>[^<]*</title>' | head -1 \
       | sed 's|<title>||;s|</title>||;s| - Spell.*||;s| - World of Warcraft.*||')
  if [ -z "$wh" ]; then
    fail=$((fail+1)); printf 'FETCHFAIL  %-8s %s\n' "$sid" "$name"
  elif [ "$wh" = "$name" ] || [ "$wh" = "Summon $name" ]; then
    ok=$((ok+1))
  else
    bad=$((bad+1)); printf 'MISMATCH   %-8s ours=%-32s wowhead=%s\n' "$sid" "$name" "$wh"
  fi
  sleep 0.35
done < /tmp/mm_pairs.tsv
echo
echo "verified=$ok  mismatched=$bad  fetchfail=$fail  (of $total)"
[ "$bad" -eq 0 ] || echo "NOTE: 'Summon X' vs 'X' is expected for paladin/warlock mounts and is treated as OK."

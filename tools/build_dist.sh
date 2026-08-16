#!/bin/bash
# Build the CurseForge upload folder from the .toc manifest.
# Nothing is copied unless the toc names it, so dev files cannot leak by
# omission -- delete-after-copy would ship whatever we forgot to delete.
set -e
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist/MasterMountsWorldTour
python3 - <<'PY'
import pathlib,shutil
src=pathlib.Path('.'); dst=pathlib.Path('dist/MasterMountsWorldTour')
toc=pathlib.Path('MasterMountsWorldTour.toc').read_text()
out,dev,copied,missing=[],0,0,[]
DEV=('DEV ONLY','RareLootHarvest','RareScanner','Shipping it would',
     'resolved once in-game','have the answer to')
for line in toc.splitlines():
    s=line.strip()
    if s.startswith('tools\\') or s.startswith('tools/'): dev+=1; continue
    if s.startswith('#'):
        if any(k in s for k in DEV) or set(s)<=set('# -'): continue
        out.append(line); continue
    if s=='': out.append(line); continue
    f=src/s.replace('\\','/')
    if not f.exists(): missing.append(s); continue
    t=dst/s.replace('\\','/'); t.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(f,t); copied+=1; out.append(line)
(dst/'MasterMountsWorldTour.toc').write_text('\n'.join(out).rstrip()+'\n')
shutil.copytree(src/'Media', dst/'Media', dirs_exist_ok=True)
# THE LICENCE SHIPS WITH THE COPY, because the licence says so: "shall be
# included in all copies or substantial portions of the Software". It lived in
# the git repo only, so every CurseForge download -- the copies that actually
# reach people -- went out without it. Copied outside the toc manifest on
# purpose: the toc lists what the CLIENT loads, and a licence is not that.
if (src/'LICENSE').exists():
    shutil.copy2(src/'LICENSE', dst/'LICENSE')
else:
    raise SystemExit('LICENSE missing from the source folder -- refusing to build an unlicensed copy')
# NOTICE travels with LICENSE and for the same reason. The MIT grant covers our
# code; the Modern theme artwork is another author's, used with permission and
# not ours to sub-license. A download carrying the grant without the exception
# tells the reader something untrue.
if (src/'NOTICE').exists():
    shutil.copy2(src/'NOTICE', dst/'NOTICE')
else:
    raise SystemExit('NOTICE missing -- it scopes the licence around third-party art; refusing to build without it')
listed={l.strip().replace('\\','/') for l in out if l.strip() and not l.strip().startswith('#')}
disk={str(p.relative_to(dst)) for p in dst.rglob('*.lua')}
print('copied %d | dev lines dropped %d'%(copied,dev))
print('missing from disk :',missing or 'none')
print('unlisted strays   :',sorted(disk-listed) or 'none')
assert not missing and not (disk-listed), "dist does not match the toc"
PY
f=0; for x in $(find dist -name '*.lua'); do luac -p "$x" >/dev/null 2>&1 || { echo "SYNTAX FAIL $x"; f=1; }; done
[ $f -eq 0 ] && echo "syntax 0 failures / $(find dist -name '*.lua'|wc -l|tr -d ' ')"
du -sh dist/MasterMountsWorldTour

# ---------------------------------------------------------------------------
# The CurseForge upload zip.
#
# CurseForge REJECTS an archive containing __MACOSX:
#   "Archive contains blacklisted directories:
#    __MACOSX/MasterMountsWorldTour/Libs/._LibDBIcon-1.0.lua"
#
# Those entries are macOS AppleDouble sidecars. They appear because the build
# above uses shutil.copy2, which faithfully copies extended attributes, and
# `zip` then writes a ._ sidecar for every file that has any. So the fix is
# three belts and a check, in this order:
#
#   1. xattr -cr    -- remove the attributes, so there is nothing to sidecar
#   2. COPYFILE_DISABLE=1 and -X -- tell zip not to write them anyway
#   3. zip -d       -- delete any that got in regardless
#   4. VERIFY, and fail the build if one survived. A silent slip here is a
#      rejected upload, and the rejection arrives minutes later on their site
#      rather than here.
# ---------------------------------------------------------------------------
VERSION=$(sed -n 's/^## Version: *//p' MasterMountsWorldTour.toc | head -1 | tr -d '\r')
[ -n "$VERSION" ] || { echo "no '## Version:' in the toc -- refusing to name a zip"; exit 1; }
ZIP="MasterMountsWorldTour-$VERSION.zip"

command -v xattr >/dev/null 2>&1 && xattr -cr dist/MasterMountsWorldTour
find dist -name '.DS_Store' -delete

# Zipped from INSIDE dist/, so the archive root is the addon folder itself --
# which is the layout the game and CurseForge both expect.
( cd dist && COPYFILE_DISABLE=1 zip -q -X -r "$ZIP" MasterMountsWorldTour )

( cd dist && zip -q -d "$ZIP" '__MACOSX/*' '*/._*' '._*' '*/.DS_Store' '.DS_Store' >/dev/null 2>&1 ) || true

BAD=$( cd dist && unzip -Z1 "$ZIP" | grep -E '(^|/)(__MACOSX|\._|\.DS_Store)' || true )
if [ -n "$BAD" ]; then
	echo "REFUSING TO SHIP -- blacklisted entries survived in $ZIP:"
	echo "$BAD" | sed 's/^/   /'
	exit 1
fi

echo "zip: dist/$ZIP  ($( cd dist && unzip -Z1 "$ZIP" | wc -l | tr -d ' ') entries, $(du -h "dist/$ZIP" | cut -f1)) -- no __MACOSX, ready to upload"

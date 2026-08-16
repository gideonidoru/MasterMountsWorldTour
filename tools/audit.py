#!/usr/bin/env python3
"""Static audit for Master Mounts.

Five times in one session a call was written to a function that did not exist
(InvalidateRanking, Tests.lastRun, MM.Handlers, UI.MonitorShown,
Timewalking.Active). Lua does not complain until the line runs, and a line that
runs only when a rare mount drops may not run for months. `luac -p` cannot see
it either: MM.Planner.Nonexistent() is valid syntax.

So it gets its own pass, and the pass PROVES ITSELF: --selftest injects known
bad calls and requires them to be caught. A checker that cannot fail is a
checker that reports a false all-clear, which is worse than no checker.
"""
import re, sys, glob, collections, os

def strip(s):
    s = re.sub(r'--\[\[.*?\]\]', '', s, flags=re.S)
    s = re.sub(r'--[^\n]*', '', s)
    s = re.sub(r'"[^"\n]*"', '""', s)
    return re.sub(r"'[^'\n]*'", "''", s)

def load(extra=None):
    files = [f for f in glob.glob("**/*.lua", recursive=True)
             if not f.startswith(("Libs/", "tools/", "Data/"))]
    out = {f: strip(open(f, encoding="utf-8").read()) for f in files}
    if extra:
        out["<injected>"] = strip(extra)
    return out

def resolve(clean):
    """Every MM.<Module>.<name> that something defines."""
    defined = collections.defaultdict(set)
    for s in clean.values():
        for m in re.finditer(r'function\s+MM\.(\w+)[.:](\w+)', s):
            defined[m.group(1)].add(m.group(2))
        for m in re.finditer(r'MM\.(\w+)\.(\w+)\s*=', s):
            defined[m.group(1)].add(m.group(2))
        for am in re.finditer(r'local\s+(\w+)\s*=\s*MM\.(\w+)\b', s):
            alias, mod = am.group(1), am.group(2)
            for m in re.finditer(r'function\s+' + alias + r'[.:](\w+)', s):
                defined[mod].add(m.group(1))
            for m in re.finditer(r'\b' + alias + r'\.(\w+)\s*=', s):
                defined[mod].add(m.group(1))
        for m in re.finditer(r'MM\.(\w+)\s*=\s*\{', s):
            defined.setdefault(m.group(1), set())
    return defined

# Fields that are data rather than functions, set up elsewhere or by the client.
ALLOW = {"lastRun", "SECTIONS", "route", "totals", "PRESETS", "TIER", "URGENCY",
         "SLIDERS", "DEFAULT_ORDER", "mounts", "byMountID", "bySpell", "ready",
         "collectedCount", "totalCount", "active", "scanned", "deferred",
         "unrouted", "capReport", "weaveReport", "rejections", "considered",
         "LENGTHS", "SCHEMA", "KINDS", "blocksSkipped", "lastBuildMs",
         "playerFaction", "PREFIX", "Handlers", "inReport", "lastHarvest"}

def unresolved(clean, defined):
    bad = []
    for f, s in clean.items():
        for i, line in enumerate(s.split("\n"), 1):
            for m in re.finditer(r'MM\.(\w+)\.(\w+)', line):
                mod, fn = m.group(1), m.group(2)
                if mod not in defined or fn in defined[mod] or fn in ALLOW:
                    continue
                if fn[0].isupper() or fn.startswith("last"):
                    bad.append((f, i, f"MM.{mod}.{fn}"))
    return bad

def forward_calls():
    """A file-level local CALLED above its declaration becomes a global nil."""
    bad = []
    for f in glob.glob("**/*.lua", recursive=True):
        if f.startswith(("Libs/", "tools/", "Data/")):
            continue
        src = open(f, encoding="utf-8").read().split("\n")
        decl = {}
        for i, l in enumerate(src, 1):
            m = re.match(r'local (?:function )?([A-Za-z_]\w*)', l)
            if m and m.group(1) not in decl:
                decl[m.group(1)] = i
        for name, d in decl.items():
            for i, l in enumerate(src[:d - 1], 1):
                code = strip(l)
                if re.search(r'\b' + re.escape(name) + r'\s*\(', code) \
                        and not re.match(r'\s*local\s', l):
                    bad.append((f, i, name, d))
                    break
    return bad


# ---------------------------------------------------------------------------
# Standard-Lua globals the WoW client does not provide.
#
# This exists because `debug.getinfo` shipped in Core.lua and every module
# failed to load. Nothing caught it: `luac -p` sees valid syntax, and the
# offline harness passed because standalone Lua HAS a debug table. The client
# does not. Only files the .toc actually loads are checked -- tools/ and
# Data/_source/ run under real Lua, where these are fine.
FORBIDDEN = {
    "debug":     "the debug table is stripped from the WoW addon environment",
    "io":        "no file IO in the client",
    "package":   "no module system in the client",
    "require":   "no module system in the client",
    "dofile":    "no file IO in the client",
    "loadfile":  "no file IO in the client",
}

# Lua 5.2+ ONLY. WoW runs 5.1, so these are nil at run time and blow up as
# "attempt to call a nil value" -- which is what coroutine.isyieldable() did:
# it emptied the farm plan on every build, and nothing here noticed because the
# table it hangs off (`coroutine`) exists perfectly well.
LUA_52_ONLY = {
    "coroutine.isyieldable": "Lua 5.2+; use coroutine.running() on 5.1",
    "coroutine.close":       "Lua 5.4+",
    "table.pack":            "Lua 5.2+",
    "table.unpack":          "Lua 5.2+; the 5.1 spelling is unpack()",
    "table.move":            "Lua 5.3+",
    "math.type":             "Lua 5.3+",
    "math.tointeger":        "Lua 5.3+",
    "math.ult":              "Lua 5.3+",
    "rawlen":                "Lua 5.2+",
    "os.exit":               "not in the client",
}


def wrong_dialect(sources):
    """Functions that exist in later Lua but not in the 5.1 the client runs."""
    bad = []
    shipped = set(shipped_files())
    for f, code in sources.items():
        if f.replace("\\", "/") not in shipped:
            continue
        for i, l in enumerate(code.split("\n"), 1):
            if l.lstrip().startswith("--"):
                continue
            for name, why in LUA_52_ONLY.items():
                if re.search(r'(?<![\w.])' + re.escape(name) + r'\s*\(', l):
                    bad.append((f, i, name, why))
    return bad


def shipped_files():
    """Only what the .toc loads. Everything else runs under real Lua."""
    out = []
    toc = "MasterMountsWorldTour.toc"
    if not os.path.exists(toc):
        return out
    for line in open(toc, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.endswith(".lua") and not line.startswith("#"):
            out.append(line.replace("\\", "/"))
    return out

# Lua block keywords, in the order they appear on a line. Counted on
# comment-stripped, literal-blanked source, so an `end` inside a string cannot
# close a block that is still open.
_BLOCK = re.compile(r'\b(function|if|for|while|repeat|do|end|until|elseif)\b')

def function_extents(lines):
    """[(start, end)] 0-based inclusive line spans for every `function` block.

    A fixed window of five lines was the old rule's whole idea of scope, so it
    missed Planner:Optimize -- which declares a helper between the build and the
    read -- and every diagnostic that wraps the call in a pcall. Knowing where a
    function actually ends costs one pass and removes the guesswork.
    """
    stack, out = [], []
    for i, line in enumerate(lines):
        prev = None
        for m in _BLOCK.finditer(line):
            tok = m.group(1)
            if tok == "elseif":
                prev = tok
                continue                      # opens nothing, closes nothing
            if tok == "do" and prev in ("for", "while"):
                prev = tok
                continue                      # the for/while already opened it
            if tok in ("function", "if", "for", "while", "repeat", "do"):
                stack.append((tok, i))
            elif tok in ("end", "until") and stack:
                kind, at = stack.pop()
                if kind == "function":
                    out.append((at, i))
            prev = tok
    return out

def _enclosing(extents, line, skip_same_line=False):
    """The innermost function span containing `line`.

    `skip_same_line` steps outward past a closure that OPENS on this very line,
    which is how `pcall(function() return R:Build() end)` gets attributed to the
    function that wrote it rather than to the throwaway wrapper.
    """
    best = None
    for start, stop in extents:
        if start <= line <= stop:
            if skip_same_line and start == line:
                continue
            if best is None or start > best[0]:
                best = (start, stop)
    return best

# A build that is asked for and not waited on.
_ASYNC_BUILD = re.compile(r'\b\w+[:.]Build\s*\(')
# `Build(force, true)` is the synchronous form -- it is what BuildSync calls.
_SYNC_FORM = re.compile(r'\bBuild\s*\([^()]*,\s*true\s*\)')
# Reading what a build was supposed to produce.
# `routeIndex` and `routeGoal` belong here as much as `route` does: both are
# written by Publish, so reading either straight after an asynchronous Build
# reads what the PREVIOUS build left. A self-test did exactly that and reported
# the router for the index it had written itself.
_BUILD_READ = re.compile(r'\.(route|totals|unrouted|deferred|stopBySpell|'
                         r'builtRouteCount|baseOrder|routeIndex|routeGoal)\b')
# Anything that means "and now it has landed".
#
# BUILD_CURRENT is one of them: a caller that has checked the status against it
# has established that no build started and the route already is this plan's.
# That is a completion check, not a line to be excused with an annotation.
_SETTLED = re.compile(r'\b(BuildSync|AfterBuild|IsBuilding|Warm'
                      r'|BUILD_CURRENT|BUILD_COMPLETED)\b')

def _allowed_lines(path):
    """Line numbers carrying an explicit `audit-allow`.

    Read from the RAW file: load() strips comments before anything sees them,
    and the marker is a comment.
    """
    try:
        raw = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return set()
    return {n for n, line in enumerate(raw) if "audit-allow" in line}

def build_then_read(sources):
    """An asynchronous Build() followed by a read of what it was to produce.

    Build returns with the work IN FLIGHT. Anything that asks for a build and
    then reads Router.route gets the PREVIOUS route -- silently, and only when
    the plan has changed, which is the one case anybody cares about. That shape
    has produced five separate bugs:

      the planner showing six mounts after a /mm report
      the speed check timing an early return and reporting 0 ms
      Clear Plan drawing a route for mounts no longer planned
      the weights matrix scoring one set of weights and printing another
      Planner:Optimize sorting the plan by the route from BEFORE last

    SCOPE, NOT A LINE WINDOW. The read has to be in the same function as the
    build and before anything that waits for it. A read inside a callback --
    AfterBuild's, which is the correct shape -- sits in its own function and is
    therefore not a hit, without needing to be special-cased.
    """
    bad = []
    shipped = set(shipped_files())
    for path, code in sources.items():
        if path.replace("\\", "/") not in shipped:
            continue
        lines = code.split("\n")
        extents = function_extents(lines)
        allowed = _allowed_lines(path)
        for i, line in enumerate(lines):
            if not _ASYNC_BUILD.search(line):
                continue
            if "BuildSync" in line or _SYNC_FORM.search(line):
                continue
            if i in allowed:
                continue
            scope = _enclosing(extents, i, skip_same_line=True)
            if not scope:
                continue
            for j in range(i + 1, min(scope[1], len(lines) - 1) + 1):
                nxt = lines[j]
                if j in allowed:
                    break
                if _SETTLED.search(nxt):
                    break                     # it waited; everything after is fine
                if not _BUILD_READ.search(nxt):
                    continue
                # Only a read in the SAME function counts. A read one level in
                # is a callback body, which is the shape that is correct.
                inner = _enclosing(extents, j)
                if inner == scope:
                    bad.append((path, i + 1, nxt.strip()[:60]))
                    break
    return bad

# `local n = R:Build()` where n is then read as a number or a verdict.
_ASSIGNED = re.compile(r'\b(?:local\s+)?(\w+)\s*=\s*[^=]*?\b\w+[:.]Build\s*\(')

def build_return_as_value(sources):
    """The return of an asynchronous Build used as a count or a verdict.

    Router:Start did `local n = R:Build()` and then `if n == 0`, and formatted n
    with %d. Build returns a STATUS, and before that it returned nothing at all,
    so the zero-goal guard could never fire and an empty plan activated a route
    with nothing in it. Comparing that value to a number, or printing it as one,
    is the same mistake in every case.
    """
    bad = []
    shipped = set(shipped_files())
    for path, code in sources.items():
        if path.replace("\\", "/") not in shipped:
            continue
        lines = code.split("\n")
        extents = function_extents(lines)
        allowed = _allowed_lines(path)
        try:
            raw = open(path, encoding="utf-8").read().split("\n")
        except OSError:
            raw = lines
        for i, line in enumerate(lines):
            m = _ASSIGNED.search(line)
            if not m or "BuildSync" in line or _SYNC_FORM.search(line):
                continue
            if i in allowed:
                continue
            var = m.group(1)
            scope = _enclosing(extents, i, skip_same_line=True)
            stop = scope[1] if scope else len(lines) - 1
            numeric = re.compile(r'\b' + re.escape(var) +
                                 r'\b\s*(?:==|~=|<=|>=|<|>)\s*-?\d')
            named = re.compile(r'\b' + re.escape(var) + r'\b')
            for j in range(i + 1, min(stop, len(lines) - 1) + 1):
                nxt = lines[j]
                if j in allowed:
                    break
                hit = numeric.search(nxt)
                # `%d` LIVES IN A STRING, and strip() blanks strings before
                # anything here sees them -- so the formatted case was invisible
                # to this rule until it read the raw line. Comment lines are
                # skipped so prose about %d cannot raise it.
                if not hit and j < len(raw):
                    rawline = raw[j]
                    if not rawline.lstrip().startswith("--") and "%d" in rawline \
                            and named.search(rawline):
                        hit = True
                if hit:
                    bad.append((path, i + 1, var, nxt.strip()[:56] or raw[j].strip()[:56]))
                    break
    return bad

def readme_record_count():
    """The README's record count, against the flattened database itself.

    It said "~1,690" while the database held 1,608 -- a figure remembered once
    and then left to drift, in the one document a stranger reads first. Counted
    rather than maintained: the flat file opens every record with a bare `{` at
    one tab, which is the flattener's own output shape.
    """
    bad = []
    flat, readme = "Data/Mounts.lua", "README.md"
    if not (os.path.exists(flat) and os.path.exists(readme)):
        return bad
    records = 0
    for line in open(flat, encoding="utf-8"):
        if line.rstrip("\n") == "\t{":
            records += 1
    text = open(readme, encoding="utf-8").read()
    stated = re.search(r'curated database of ([\d,]+)', text)
    if not stated:
        bad.append((readme, 0, "no record count stated", records))
        return bad
    claimed = int(stated.group(1).replace(",", ""))
    if claimed != records:
        bad.append((readme, text[:stated.start()].count("\n") + 1,
                    f"says {claimed:,}", records))
    return bad

def scrollbar_gaps_agree():
    """Every scroll bar sits the same distance from its box.

    Spotted in a screenshot, not by any gate: the Missing Mounts bar was
    anchored 4 from its box while the Farm Plan bar beside it and the
    Collection bar on the next tab were both 6. Two pixels is nothing in
    isolation and obvious when two bars sit side by side in one window.

    Offsets are compared rather than fixed to a constant, so the house
    standard can change -- it just has to change everywhere at once.
    """
    bad = []
    found = []
    for f in sorted(glob.glob("UI/*.lua") + glob.glob("*.lua")):
        if f.startswith(("Libs/", "tools/")):
            continue
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            if line.lstrip().startswith("--"):
                continue
            m = re.search(r'\w*[Bb]ar:SetPoint\("(?:TOP|BOTTOM)LEFT",\s*\w+,\s*'
                          r'"(?:TOP|BOTTOM)RIGHT",\s*(-?\d+)', line)
            if m:
                found.append((f, i, int(m.group(1))))
    if not found:
        return bad
    gaps = collections.Counter(g for _f, _i, g in found)
    standard = gaps.most_common(1)[0][0]
    for f, i, g in found:
        if g != standard:
            bad.append((f, i, g, standard))
    return bad

def requirement_stated_not_modelled():
    """A requirement written in prose, with no condition that models it.

    Reported from play: the route offered to sell someone a mount gated behind
    Delver's Journey Rank 5, which they had not reached. Nothing was confused
    about reputation -- the record SAYS "at Delver's Journey Rank 5" in its
    source and again in its notes, and its conditions list holds the currency
    and nothing else. A gate that exists only in a sentence gates nothing.

    Prose is the input here on purpose: the sentence is the claim, and this
    rule asks whether anything backs it. Only phrasings that name a hard
    threshold count -- "Rank 5", "Renown 12", "requires Exalted" -- because
    those are the ones a player is blocked by rather than merely advised of.
    """
    bad = []
    flat = "Data/Mounts.lua"
    if not os.path.exists(flat):
        return bad
    text = open(flat, encoding="utf-8").read()
    # A NUMBERED rank is unambiguous. A bare standing is not: "Honored
    # Warrior's Cache" is the name of a treasure, and matching the word alone
    # reported Ancestral War Bear -- a chest, not a reputation -- which is
    # exactly how a rule earns the right to be ignored. Bare standings must
    # therefore read as a requirement: preceded by a cue, and not swallowed by
    # a proper noun following them.
    gate = re.compile(
        r'\b(Rank \d+|Renown \d+)\b'
        r'|(?:requires?|needs?|at|until|reach(?:ing)?)\s+'
        r'\b(Exalted|Revered|Honored)\b(?!\s+[A-Z])')
    # Split on record boundaries the flattener emits: a bare `{` at one tab.
    records = text.split("\n\t{\n")
    for rec in records[1:]:
        body = rec.split("\n\t},")[0]
        name = re.search(r'name = "([^"]+)"', body)
        if not name:
            continue
        # AN UNOBTAINABLE MOUNT'S GATE CHANGES NOTHING. The three Plunderstorm
        # mounts state a Renown rank and are already obtainable = false because
        # the Plunderstore is dormant; the router never offers them, so a
        # missing condition costs nobody anything.
        if re.search(r'obtainable = false', body):
            continue
        prose = " ".join(re.findall(r'(?:source|notes|access) = "([^"]*)"', body))
        # A DISCOUNT IS NOT A GATE. Boulder Hauler is "cheaper at Loamm Niffen
        # Renown 12" -- buyable at full price without it. Reporting a price
        # break as a requirement is the same error as reading a treasure named
        # "Honored Warrior's Cache" as a standing.
        m = gate.search(prose)
        if not m:
            continue
        before = prose[max(0, m.start() - 40):m.start()]
        if re.search(r'\b(cheaper|discount|discounted|reduced)\b', before):
            continue
        # Does ANY condition model a standing or a rank? A currency alone does
        # not: you can hold the currency and still be refused the purchase.
        conds = re.findall(r'type = "(\w+)"', body)
        if any(c in ("REP", "ACHIEVEMENT", "QUEST", "COVENANT") for c in conds):
            continue
        # A CURRENCY CONDITION COUNTS WHEN ITS AMOUNT IS THE RANK. A currency
        # alone does not model a gate -- you can hold the coin and still be
        # refused -- but a renown TRACK is a currency, and "Rank 5" modelled as
        # five of the rank currency is the gate itself rather than the price.
        # Matching on the number keeps that narrow: any other amount is a cost.
        rank = re.search(r'(?:Rank|Renown) (\d+)', m.group(1) or m.group(2) or "")
        if rank and re.search(r'amount = %s\b' % rank.group(1), body):
            continue
        line = text[:text.find(body)].count("\n") + 1
        bad.append((flat, line, name.group(1),
                    m.group(1) or m.group(2)))
    return bad

def instance_name_shared_across_expansions():
    """One instance name used by records from different expansions.

    Reported from play: the route sent someone into the Midnight version of
    Magisters' Terrace for a mount that drops in the Burning Crusade one.

    Instance identity in this addon IS the name string -- IDResolver feeds
    `rec.instance.name` into the same name-to-map pool as zones, and
    Availability keys saved lockouts on `rec.instance.name:lower()`. So a
    re-used name is not only a routing mistake: clearing one version marks the
    other as locked, and a goal the player can still do disappears.

    Expansion was the first discriminator and it was the wrong one. It reported
    Zul'Aman, where the Amani War Bear (Burning Crusade) and the Amani Battle
    Bear (Cataclysm) come from ONE dungeon that the journal lists once -- two
    mounts added in different expansions, not two dungeons. A rule that cannot
    tell those apart is noise.

    What actually settles it is `journalInstanceID`, read from a live client.
    Records that carry distinct ids are pinned and correct; records that carry
    the SAME id are one dungeon and fine; and only records with no id to tell
    them apart are still guessing, which is the case worth reporting.
    """
    bad = []
    flat = "Data/Mounts.lua"
    if not os.path.exists(flat):
        return bad
    text = open(flat, encoding="utf-8").read()
    byname = collections.defaultdict(set)
    holder = collections.defaultdict(list)
    for rec in text.split("\n\t{\n")[1:]:
        body = rec.split("\n\t},")[0]
        inst = re.search(r'instance = \{[^}]*name = "([^"]+)"', body) \
            or re.search(r'instance = \{\s*\n\s*name = "([^"]+)"', body)
        exp = re.search(r'expansion = (\d+)', body)
        nm = re.search(r'name = "([^"]+)"', body)
        if not (inst and exp and nm):
            continue
        jid = re.search(r'journalInstanceID = (\d+)', body)
        byname[inst.group(1)].add(exp.group(1))
        holder[inst.group(1)].append((nm.group(1), exp.group(1),
                                      jid.group(1) if jid else None))
    for iname, exps in sorted(byname.items()):
        if len(exps) < 2:
            continue
        ids = [j for _n, _e, j in holder[iname]]
        if all(ids) and len(set(ids)) == len(ids):
            continue          # every record pinned, and pinned differently
        if all(ids) and len(set(ids)) == 1:
            continue          # every record pinned to the SAME dungeon
        who = ", ".join(
            f"{n} (exp {e}{'' if j is None else ', id ' + j})"
            for n, e, j in sorted(holder[iname]))
        bad.append((flat, 0, iname, who))
    return bad

def missing_textures():
    """A texture path the code builds, against the files that actually exist.

    A missing texture does not throw in the client. It draws nothing, and the
    frame that wanted it looks subtly wrong in a way nobody can grep for -- the
    folder-name mismatch that once silently broke four textures here failed
    exactly this way, and no gate caught it.

    Interpolated paths are expanded rather than skipped, which is the half that
    matters: sixteen button textures are named only as
    `"button_warm_frame_" .. state .. "_left.tga"`, so a literal-only scan sees
    them as unreferenced and a file check sees them as unverifiable. The states
    are read from the same table the code loops over.
    """
    bad = []
    media = "Media"
    if not os.path.isdir(media):
        return bad
    on_disk = {p.replace("\\", "/").lower()
               for p in glob.glob("Media/**/*", recursive=True)}

    def exists(rel):
        return ("media/" + rel.replace("\\", "/").lower()) in \
               {p.lower() for p in on_disk} or \
               os.path.exists(os.path.join("Media", rel.replace("\\", "/")))

    for f in glob.glob("**/*.lua", recursive=True):
        if f.startswith(("Libs/", "tools/", "Data/", "HandyNotes")):
            continue
        text = open(f, encoding="utf-8", errors="replace").read()
        states = re.findall(r'STATES\s*=\s*\{([^}]*)\}', text)
        names = re.findall(r'"(\w+)"', states[0]) if states else \
            ["normal", "hover", "pressed", "disabled"]
        for i, line in enumerate(text.split("\n"), 1):
            if line.lstrip().startswith("--"):
                continue
            # MODERN .. "literal.tga"  /  MM.MEDIA .. "literal.tga"
            for m in re.finditer(r'(MODERN|MM\.MEDIA)\s*\.\.\s*"([\w./\\-]+\.\w+)"', line):
                sub = "Modern/" if m.group(1) == "MODERN" else ""
                if not exists(sub + m.group(2)):
                    bad.append((f, i, sub + m.group(2)))
            # MODERN .. "prefix_" .. state .. "_suffix.tga"
            for m in re.finditer(
                    r'(MODERN|MM\.MEDIA)\s*\.\.\s*"([\w-]+_)"\s*\.\.\s*\w+\s*\.\.\s*"(_[\w.-]+\.\w+)"',
                    line):
                sub = "Modern/" if m.group(1) == "MODERN" else ""
                for st in names:
                    rel = sub + m.group(2) + st + m.group(3)
                    if not exists(rel):
                        bad.append((f, i, rel))
    return bad

def readme_test_count():
    """A stated check count, against the checks Tests.lua actually registers.

    The README advertised 145 while the suite had grown to 205 -- the same
    failure as the record count, in the same document, found the same way. A
    number in prose is a claim nobody re-derives, so it is derived here instead.

    Both READMEs are examined: the source folder's, and the release repo's
    beside it if that is where the sentence lives. A missing file is not a
    finding -- only a stated number that disagrees is.
    """
    bad = []
    tests = "Tests.lua"
    if not os.path.exists(tests):
        return bad
    registered = len(re.findall(r'^\s*check\("', open(tests, encoding="utf-8").read(), re.M))
    if registered == 0:
        return bad
    candidates = ["README.md",
                  os.path.join("..", "MasterMountsWorldTour-release", "README.md")]
    for readme in candidates:
        if not os.path.exists(readme):
            continue
        text = open(readme, encoding="utf-8").read()
        for m in re.finditer(r'\(([\d,]+) of them\)', text):
            claimed = int(m.group(1).replace(",", ""))
            if claimed != registered:
                bad.append((readme, text[:m.start()].count("\n") + 1,
                            claimed, registered))
    return bad

def donate_url_agrees():
    """The support address in the toc, against the one the options panel shows.

    It is written down twice -- `## X-Donate` for addon managers, and a copy
    box in the options panel for the player -- so it can be changed in one
    place and left wrong in the other. A donation link that quietly points at
    the old address is worse than none: it fails silently and takes the money
    with it. Counted rather than trusted, the same way the README count is.
    """
    bad = []
    toc, opts = "MasterMountsWorldTour.toc", "Options.lua"
    if not (os.path.exists(toc) and os.path.exists(opts)):
        return bad
    stated = None
    for i, line in enumerate(open(toc, encoding="utf-8"), 1):
        m = re.match(r"##\s*X-Donate:\s*(\S+)", line)
        if m:
            stated, at = m.group(1).strip(), i
    if not stated:
        return bad
    text = open(opts, encoding="utf-8").read()
    shown = re.findall(r'"(https?://[^"]+)"', text)
    if not shown:
        bad.append((toc, at, stated, "the options panel shows no address at all"))
    elif stated not in shown:
        bad.append((toc, at, stated, "the options panel shows " + ", ".join(sorted(set(shown)))))
    return bad

def forbidden_globals(sources):
    bad = []
    shipped = set(shipped_files())
    for f, code in sources.items():
        if f.replace("\\", "/") not in shipped:
            continue
        for i, l in enumerate(code.split("\n"), 1):
            if l.lstrip().startswith("--"):
                continue
            for name, why in FORBIDDEN.items():
                # `debug.x` / `require(` -- a bare mention in a string is fine
                # \w, not %w -- a Lua character class inside a Python regex
                # matched "scenario." and "CreateRadio(" as uses of `io`.
                if re.search(r'(?<![\w.])' + name + r'\s*[.(]', l):
                    if name == "debug" and re.search(r'debug(stack|profilestop)', l):
                        continue
                    bad.append((f, i, name, why))
                    break
    return bad

def upvalue_used_before_declared(fname):
    """A file-level local CONSTANT read above the line that declares it.

    Lua resolves that to a global, so it is nil at runtime and the first
    arithmetic on it throws -- while the file compiles cleanly and the
    forward-CALL pass says nothing, because this is a read, not a call.

    Written after doing exactly this: two cost constants placed below the
    function that spends them. luac -p was happy and the audit was happy.
    """
    try:
        lines = open(fname, encoding="utf-8").read().split("\n")
    except OSError:
        return []
    declared = {}
    for i, line in enumerate(lines):
        m = re.match(r"^local\s+([A-Z][A-Z0-9_]{2,})\s*=", line)
        if m and m.group(1) not in declared:
            declared[m.group(1)] = i
    bad = []
    for nm, decl in declared.items():
        for i, line in enumerate(lines[:decl]):
            if line.lstrip().startswith("--"):
                continue
            if re.search(r"\b" + nm + r"\b", line):
                bad.append((fname, i + 1, nm, decl + 1))
                break
    return bad


# ---------------------------------------------------------------------------
# A unit's NAME, read without a guard.
#
# Midnight hands a tainted addon SECRET values for several payloads, and a
# secret is not a string: concatenating it, lowering it or formatting it throws
# "attempt to perform string conversion on a secret value".
#
# ONLY UnitName, AND ONLY FOR SOMEBODY ELSE. The player's own name is never
# withheld -- every character key in this addon is built from one -- and the
# other payloads that have turned out to be secret (a boss name, a vignette
# name) do not come from a function this can spot. UnitClass was in an earlier
# draft of this rule on the assumption it behaved the same way; there is no
# evidence it does, and a build rule asserting something unproven is worse than
# no rule at all.
#
# This exists because the same mistake shipped three times: the boss name, then
# a vignette name a delve found, then three unit events at once that a delve
# found -- each in a different file, each a few lines from something already
# guarded, and each costing a live report because nothing pointed at the next.
# MM.Util.ReadableString is the one place that asks whether a string can be
# read.
def upvalue_written_before_declared(fname):
    """A file-level local ASSIGNED above the line that declares it.

    Worse than the read this file already checks for, and caught later: a read
    resolves to a global and is nil, which usually throws on first use. A WRITE
    silently creates a global and leaves the real local untouched -- the code
    runs, nothing errors, and the variable it meant to change never changes.

    Written after doing exactly this: TP.SetOff cleared a cached snapshot 190
    lines above `local snapshot`, so switching a teleport off invalidated a
    global nobody reads and the router kept serving the stale list. luac was
    happy, the forward-call pass was happy, and the existing upvalue rule only
    looks at UPPERCASE constants and only at reads.
    """
    try:
        lines = open(fname, encoding="utf-8").read().split("\n")
    except OSError:
        return []
    declared = {}
    for i, line in enumerate(lines):
        m = re.match(r"^local\s+([a-zA-Z_][\w_]*(?:\s*,\s*[a-zA-Z_][\w_]*)*)\s*(?:=|$)", line)
        if not m:
            continue
        for nm in [n.strip() for n in m.group(1).split(",")]:
            if nm and nm not in declared:
                declared[nm] = i
    bad = []
    for nm, decl in declared.items():
        assign = re.compile(r"^\s+" + re.escape(nm) + r"\s*=[^=]")
        for i, line in enumerate(lines[:decl]):
            if line.lstrip().startswith("--"):
                continue
            if "local " + nm in line:
                continue        # a same-named local inside some function
            if assign.match(line):
                bad.append((fname, i + 1, nm, decl + 1))
                break
    return bad

def scattered_guid_parses():
    """strsplit on a GUID outside Util.lua.

    A GUID is a client-supplied string, so splitting one is a string conversion
    and throws when 12.0 withholds it. Three files each kept their own copy of
    the same six-line parse, so the fault existed in three places at once and
    the name guard added to two of them went straight past it -- the GUID is
    read on the line BEFORE the name, and nobody was looking at it.
    """
    out = []
    for fname in shipped_files():
        if fname.endswith("Util.lua") or not os.path.exists(fname):
            continue
        text = open(fname, encoding="utf-8", errors="replace").read()
        for i, line in enumerate(text.split("\n"), 1):
            if line.lstrip().startswith("--"):
                continue
            if 'strsplit("-"' in line:
                out.append((fname, i))
    return out

def unguarded_secret_reads(_ignored=None):
    # READ THE RAW FILES, NOT THE CLEANED ONES. Every other rule here works on
    # source with the string literals stripped out, which is exactly what this
    # one needs to keep: without the argument there is no way to tell our own
    # name from somebody else's, and the first version of this rule duly
    # reported eight false alarms on UnitName("player").
    out = []
    call = re.compile(r'(?<![\w_.])(UnitName|GetUnitName)\(([^)]*)\)')
    for fname in shipped_files():
        if fname.endswith("Util.lua") or not os.path.exists(fname):
            continue
        text = open(fname, encoding="utf-8", errors="replace").read()
        for i, line in enumerate(text.split("\n"), 1):
            if line.lstrip().startswith("--"):
                continue
            for m in call.finditer(line):
                arg = m.group(2).strip()
                if arg == '"player"':
                    continue        # our own name, always readable
                if "ReadableString" in line[:m.start()]:
                    continue
                out.append((fname, i, m.group(1),
                            "a unit's name is secret inside an instance"))
    return out

def deferred_without_flush():
    """A secure attribute deferred by combat, with nothing to apply it later.

    SetAttribute is refused in combat, so every caller learns to wrap it in an
    InCombatLockdown check. The half that keeps getting left out is the RETURN:
    unless something re-applies the value on PLAYER_REGEN_ENABLED, the deferred
    write is simply dropped and the control stays dead for the rest of its life.

    That has now happened twice in this addon -- the arrow's visibility, then
    the rare alert's target button -- and both times the guard was present and
    correct while the flush was absent, which is why reading the guard is not
    enough to tell them apart.

    A file that writes a secure attribute AND mentions InCombatLockdown must
    therefore also name PLAYER_REGEN_ENABLED. Files that never defer are not the
    subject.

    SetShownWhenCombatAllows IS NOT AN EXCUSE, and the first version of this rule
    accepted it as one -- which made the rule report a clean zero against the
    very bug it was written for. That helper defers SHOW AND HIDE and owns a
    PLAYER_REGEN_ENABLED of its own for them; it knows nothing about attributes.
    RareAlert used it for the frame and deferred the attribute by hand, so the
    exemption matched, the rule passed, and the dead button stayed dead. Caught
    only by removing the flush and watching the rule fail to notice.
    """
    out = []
    for fname in shipped_files():
        if not os.path.exists(fname) or fname.endswith("Util.lua"):
            continue
        text = open(fname, encoding="utf-8", errors="replace").read()
        code = strip(text)
        if "SetAttribute(" not in code or "InCombatLockdown" not in code:
            continue
        # LITERALS KEPT, COMMENTS DROPPED -- and it has to be exactly that.
        #
        # strip() blanks every string, so the event name could never match and
        # the rule called both correct files faults. Reading raw text instead
        # swung it the other way: every one of these files EXPLAINS the flush in
        # a comment, so the rule saw the word, exempted the file, and went quiet
        # again -- including with the flush deleted. Two failures in opposite
        # directions, both invisible until the fault was injected.
        live = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.S)
        live = re.sub(r'--[^\n]*', '', live)
        if "PLAYER_REGEN_ENABLED" in live:
            continue
        for i, line in enumerate(code.split("\n"), 1):
            if "SetAttribute(" in line:
                out.append((fname, i))
                break
    return out


def unknown_slash_commands():
    """A /mm command named in shipped text that the dispatcher does not accept.

    `/mm test` is not a command. Two user-facing messages told the player to run
    it anyway -- the scorecard's "nothing measurable yet" line and the self-test
    check behind it -- and typing it falls through to the help list, which reads
    like a typo rather than like being sent somewhere that does not exist. Two
    comments pointed the next author the same way.

    Nothing could catch that: the string is valid Lua, the command is a live one
    in spirit (selftest, check and report all do the job), and only somebody
    typing it finds out. So the dispatcher's own branches are the list, and any
    /mm word in shipped source has to appear in it.

    Comments are stripped first, and deliberately: prose runs "/mm is the
    command" and "the /mm commands", which are English rather than instructions.
    """
    core = open("Core.lua", encoding="utf-8", errors="replace").read()
    known = set(re.findall(r'input == "([a-z]+)"', core))
    known |= set(re.findall(r'input:match\("\^([a-z]+)', core))
    # The report-shaped commands are a TABLE, not branches. This rule found its
    # own blind spot the moment they moved: twenty-three working commands were
    # reported as non-existent because the dispatcher had changed shape and the
    # rule still only knew one of its two shapes.
    tbl = re.search(r'WINDOWED_COMMANDS\s*=\s*\{(.*?)\n\}', core, re.S)
    if tbl:
        known |= set(re.findall(r'^\s*([a-z][a-z0-9]*)\s*=\s*\{', tbl.group(1), re.M))
    if not known:
        return []                      # cannot judge; say nothing rather than lie
    out = []
    for fname in shipped_files():
        if not os.path.exists(fname):
            continue
        text = open(fname, encoding="utf-8", errors="replace").read()
        live = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.S)
        live = re.sub(r'--[^\n]*', '', live)
        for i, line in enumerate(live.split("\n"), 1):
            for m in re.finditer(r'/mm\s+([a-z]+)', line):
                if m.group(1) not in known:
                    out.append((fname, i, m.group(1)))
    return out


def patch121_overridden():
    """A later file replacing the authoritative 12.1 location with a stand-in.

    ORDER.txt makes the last write win, which is right for filling gaps and wrong
    when the later file holds older knowledge. `Data_91_LocationsB.lua` exists to
    give a zone to records that shipped without one, and it was written against
    the stubs in `Data_13_GapFill.lua`. `Data_15_Patch121.lua` later defined the
    same mounts properly -- and loads FIRST -- so its locations were silently
    replaced.

    Five 12.1 mounts were wrong because of it, and every one looked fine: the
    zones named are real, the coordinates are inside them, and the self-test only
    asks whether a goal HAS a place.

      Spirit of Tok'jara        Zul'Aman, at the AMANI quartermaster, for a Coiled
                                Isle renown chain
      Sea-Dwelling Isle Serpent Jan'sari the Watchful instead of the vendor who
                                sells it -- right island, wrong vendor
      Primeval Skyfriend        a Coiled Isle hub instead of the raid it drops in
      Crimson Venomfang         the same
      The Writhing Brood        a Coiled Isle hub instead of Altar of Fangs

    Two shapes are reported and nothing else, so filling a genuine gap stays
    allowed: naming a DIFFERENT zone than Data_15 does, and giving a zone to a
    record whose location is an `instance` -- GetRecordLocation prefers a usable
    zone over everything, so that one silently wins over the door.
    """
    base = "Data/_source/Data_15_Patch121.lua"
    order_path = "Data/_source/ORDER.txt"
    if not (os.path.exists(base) and os.path.exists(order_path)):
        return []
    text = open(base, encoding="utf-8", errors="replace").read()
    consts = dict(re.findall(r'^local ([A-Z_]+)\s*=\s*[\'"](.*?)[\'"]', text, re.M))

    # One record per "{ name = " at this file's indent; take the zone/instance of each.
    owned = {}
    for chunk in re.split(r'\n\t\{ name = ', text)[1:]:
        nm = re.match(r'"(.*?)"', chunk)
        if not nm:
            continue
        zm = re.search(r'zone = \{([^}]*)\}', chunk)
        im = re.search(r'instance = \{([^}]*)\}', chunk)
        zone = None
        if zm:
            z = re.search(r'name = ("?[^,"}]+"?)', zm.group(1))
            if z:
                raw = z.group(1).strip().strip('"')
                zone = consts.get(raw, raw)
        owned[nm.group(1)] = (zone, bool(im))

    files = [l.strip() for l in open(order_path, encoding="utf-8")
             if l.strip() and not l.strip().startswith("#")]
    later = files[files.index(os.path.basename(base)) + 1:] \
        if os.path.basename(base) in files else []

    out = []
    for fname in later:
        path = os.path.join("Data/_source", fname)
        if not os.path.exists(path):
            continue
        for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            m = re.match(r'\s*MM\.OverrideMount\(\s*"(.*?)"\s*,\s*\{.*?'
                         r'zone\s*=\s*\{[^}]*?name\s*=\s*"(.*?)"', line)
            if not m:
                continue
            name, zone = m.group(1), m.group(2)
            if name not in owned:
                continue
            ownZone, hasInstance = owned[name]
            if ownZone and zone != ownZone:
                out.append((fname, i, name,
                            "names %s; Data_15_Patch121 says %s" % (zone, ownZone)))
            elif hasInstance and not ownZone:
                out.append((fname, i, name,
                            "adds zone %s to a record located by its instance" % zone))
    return out


def main():
    if "--selftest" in sys.argv:
        injected = ("local x = MM.Planner.InvalidateRanking\n"
                    "local y = MM.Tests.NotARealThing()\n")
        clean = load(injected)
        caught = [b for b in unresolved(clean, resolve(clean)) if b[0] == "<injected>"]
        injected2 = load("local i = debug.getinfo(1)\nlocal j = require('x')\n")
        caught2 = [b for b in forbidden_globals(injected2) if b[0] == "<injected>"]
        # the injected file is not in the .toc, so force it through the check
        if not caught2:
            fake = {"Core.lua": "local i = debug.getinfo(1)\nlocal j = require('x')\n"}
            caught2 = forbidden_globals(fake)
        print(f"selftest: {len(caught)} of 2 injected MM.* faults caught")
        for f, i, ref in caught:
            print(f"   caught {ref}")
        print(f"selftest: {len(caught2)} of 2 injected client-global faults caught")
        for f, i, name, why in caught2:
            print(f"   caught {name}")
        return 0 if (len(caught) == 2 and len(caught2) == 2) else 1

    clean = load()
    bad = unresolved(clean, resolve(clean))
    fwd = forward_calls()
    print(f"unresolved MM.* references : {len(bad)}")
    for f, i, ref in bad:
        print(f"   {f}:{i}  {ref}")
    print(f"file-level forward calls   : {len(fwd)}")
    for f, i, n, d in fwd:
        print(f"   {f}:{i}  calls `{n}` declared at {d}")
    gone = forbidden_globals(clean)
    print(f"globals the client lacks   : {len(gone)}")
    for f, i, n, why in gone:
        print(f"   {f}:{i}  uses `{n}` — {why}")
    dialect = wrong_dialect(clean)
    print(f"wrong Lua dialect          : {len(dialect)}")
    for f, i, n, why in dialect:
        print(f"   {f}:{i}  uses `{n}` — {why}")
    early = []
    for f in clean:
        early += upvalue_used_before_declared(f)
    written = []
    for f in shipped_files():
        if os.path.exists(f):
            written += upvalue_written_before_declared(f)
    print(f"constants read before decl : {len(early)}")
    for f, i2, n, d in early:
        print(f"   {f}:{i2}  reads `{n}` declared at {d}")
    secret = unguarded_secret_reads()
    print(f"a unit name read raw       : {len(secret)}")
    for f, i4, n, why in secret:
        print(f"   {f}:{i4}  `{n}` unguarded — {why}; use MM.Util.ReadableString")
    guids = scattered_guid_parses()
    print(f"a GUID split outside Util  : {len(guids)}")
    for f, i5 in guids:
        print(f"   {f}:{i5}  splits a GUID here — use MM.Util.NpcIDFromGUID")
    print(f"a local written above it  : {len(written)}")
    for f, i6, n, d in written:
        print(f"   {f}:{i6}  assigns `{n}` declared at {d} -- this writes a GLOBAL")
    btr = build_then_read(clean)
    print(f"build, then read the route : {len(btr)}")
    for f, i3, snippet in btr:
        print(f"   {f}:{i3}  Build() then `{snippet}` -- use BuildSync()")
    retval = build_return_as_value(clean)
    print(f"build's return used as a count: {len(retval)}")
    for f, iv, var, snippet in retval:
        print(f"   {f}:{iv}  `{var}` is a build STATUS, read as a number at `{snippet}`")
    counts = readme_record_count()
    print(f"README record count drift  : {len(counts)}")
    for f, ic, said, real in counts:
        print(f"   {f}:{ic}  {said}, the flattened database holds {real:,}")
    zones = patch121_overridden()
    print(f"12.1 location overridden  : {len(zones)}")
    for f, i9, name, why in sorted(zones):
        print(f"   {f}:{i9}  {name} -- {why}")
    slash = unknown_slash_commands()
    print(f"a command that does not exist: {len(slash)}")
    for f, i8, c in slash:
        print(f"   {f}:{i8}  names `/mm {c}`, which the dispatcher does not accept")
    gaps = scrollbar_gaps_agree()
    print(f"a scrollbar out of line   : {len(gaps)}")
    for f, ig, got, want in gaps:
        print(f"   {f}:{ig}  sits {got} from its box; every other bar sits {want}")
    gated = requirement_stated_not_modelled()
    print(f"a gate stated, not modelled: {len(gated)}")
    for f, ig, who, phrase in gated:
        print(f"   {f}:{ig}  {who} says \"{phrase}\" and no condition models it")
    shared = instance_name_shared_across_expansions()
    print(f"one instance, two expansions: {len(shared)}")
    for f, _i, iname, who in shared:
        print(f"   {iname} -- {who}")
    tex = missing_textures()
    print(f"a texture that is not there : {len(tex)}")
    for f, itx, rel in tex:
        print(f"   {f}:{itx}  Media/{rel} is referenced and not on disk")
    tcount = readme_test_count()
    print(f"README test count drift  : {len(tcount)}")
    for f, itc, said, real in tcount:
        print(f"   {f}:{itc}  says {said}, Tests.lua registers {real}")
    donate = donate_url_agrees()
    print(f"support address disagrees : {len(donate)}")
    for f, idn, said, why in donate:
        print(f"   {f}:{idn}  toc says {said} -- {why}")
    noflush = deferred_without_flush()
    print(f"deferred attr, never flushed: {len(noflush)}")
    for f, i7 in noflush:
        print(f"   {f}:{i7}  defers SetAttribute in combat and never re-applies it "
              f"-- flush on PLAYER_REGEN_ENABLED")
    return 1 if (bad or fwd or gone or early or btr or retval or secret or guids
                 or written or noflush or slash or zones or counts or donate or tcount or tex or gated or shared or gaps) else 0

if __name__ == "__main__":
    sys.exit(main())

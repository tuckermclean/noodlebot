#!/bin/sh
# Tests check-regime.py: a valid two-node repository passes; each kind of mistake is reported.
#   sh plugin/skills/node/check-regime.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
# fixture: X01 (no deps) and X02 (deps X01)
fixture() {
	rm -rf "$tmp/r" && mkdir -p "$tmp/r/docs" "$tmp/r/nodes"
	printf 'template: {headings: [Purpose, Gate]}\nnodes:\n  - {id: X01, name: first, track: now, deps: []}\n  - {id: X02, name: second, track: later, deps: [X01]}\n' >"$tmp/r/docs/graph.yaml"
	printf '# X01 — first\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | X02 | S |\n\n## Purpose\nP.\n\n## Gate\n- **X01-AC-1** — one. *Verify:* t.\n- **X01-AC-2** — two. *Verify:* t.\n' >"$tmp/r/nodes/X01-first.md"
	printf '# X02 — second\n\n## Purpose\nP.\n\n## Gate\n- **X02-AC-1** — one. *Verify:* t.\n' >"$tmp/r/nodes/X02-second.md"
}
check() {  # check <name> <expected output fragment> : run after mutating the fixture
	out=$(python3 -I "$src/check-regime.py" --root "$tmp/r" 2>&1)
	if printf '%s' "$out" | grep -qF -- "$2"; then echo "PASS: $1"; else echo "FAIL: $1: want '$2' in: $out"; fails=$((fails + 1)); fi
}
fixture; check "a valid repository has no problems" "PROBLEMS 0"
fixture; sed -i 's/deps: \[X01\]/deps: [X09]/' "$tmp/r/docs/graph.yaml"; check "an unknown dep" "X02: unknown dep X09"
fixture; sed -i 's/name: first, track: now, deps: \[\]/name: first, track: now, deps: [X02]/' "$tmp/r/docs/graph.yaml"; check "a cycle" "cycle:"
fixture; rm "$tmp/r/nodes/X02-second.md"; check "a missing spec" "X02: no spec nodes/X02-second.md"
fixture; sed -i 's/| now | none | X02 | S |/| now | none | none | S |/' "$tmp/r/nodes/X01-first.md"; check "a header row that disagrees with the graph" "X01: header row"
fixture; sed -i 's/X01-AC-2/X01-AC-3/' "$tmp/r/nodes/X01-first.md"; check "a gap in the criteria" "X01: criteria numbered [1, 3]"
fixture; sed -i 's/two. \*Verify:\* t./two./' "$tmp/r/nodes/X01-first.md"; check "a criterion without Verify" "X01-AC-2: no *Verify:*"
fixture; sed -i 's/## Purpose/## Aim/' "$tmp/r/nodes/X02-second.md"; check "a missing template heading" "X02: missing headings ['Purpose']"
fixture; sed -i '1s/.*/# X02 — other/' "$tmp/r/nodes/X02-second.md"; check "a wrong title" "X02: the title is not"

# ---- A02: ownership fields (status, owns, gate, out_of_scope, adoption); fixtures in testdata/regime/
# rchk <name> <want exit> <fragment>...: run check-regime on $tmp/r; some one output line holds every fragment; exit is <want exit>
rchk() {
	rname=$1; rwant=$2; shift 2
	out=$(python3 -I "$src/check-regime.py" --root "$tmp/r" 2>&1); rrc=$?
	line=$out
	for fr in "$@"; do line=$(printf '%s\n' "$line" | grep -F -- "$fr"); done
	if [ -n "$line" ] && [ "$rrc" -eq "$rwant" ]; then echo "PASS: $rname"; else echo "FAIL: $rname: want a line with '$*' and exit $rwant, got exit $rrc: $out"; fails=$((fails + 1)); fi
}
adopt() { rm -rf "$tmp/r"; cp -R "$src/testdata/regime/${1:-adopted}" "$tmp/r"; g="$tmp/r/docs/graph.yaml"; }
# Problem texts asserted (fragments on one line): "<ID>: unknown status", "<ID>: no owns", "<ID>: track must be done",
# "<ID>-AC-<n>: unpinned", "<ID>: owns glob <glob> not in", "<glob> listed by <ID> and <ID>", "gate: required",
# "gate.command", "gate.fail_pattern", "gate.known_red", "out_of_scope", "adoption" + the area name.
adopt; rchk "A02-AC-1: the valid adopted graph (wrapped Owns paragraphs) has no problems" 0 "PROBLEMS 0"
adopt adopted-empty; rchk "A02-AC-1: an adoption with areas: [] has no problems" 0 "PROBLEMS 0"
adopt; [ ! -e "$tmp/r/src" ] && rchk "A02-AC-1: owns globs matching no file are not looked for (graph and specs only)" 0 "PROBLEMS 0"
adopt; printf 'template: {headings: [Purpose, Gate]}\nnodes:\n  - {id: X01, name: fresh, track: now, status: planned, deps: [], owns: ['"'"'tests/**/new.py'"'"']}\n' >"$g"; sed -i 's/| now | P01 | none/| now | none | none/' "$tmp/r/nodes/X01-fresh.md"
rchk "A02-AC-1: planned nodes alone need no gate and no adoption" 0 "PROBLEMS 0"
adopt; printf 'nodes: []\n' >"$g"; rchk "A02-AC-1: nodes: [] is allowed" 0 "PROBLEMS 0"
adopt; printf 'gate: {command: make test, known_red: []}\nnodes: []\n' >"$g"; rchk "A02-AC-1: known_red empty needs no fail_pattern" 0 "PROBLEMS 0"
adopt; sed -i 's/status: pinned/status: bogus/' "$g"; rchk "A02-AC-1: an unknown status" 1 "P01: unknown status"
adopt; sed -i "s/, owns: \['src\/core\/\*\*', 'src\/util.py'\]//" "$g"; rchk "A02-AC-1: an imported node without owns" 1 "I01: no owns"
adopt; sed -i "s/owns: \['src\/pin\/\*.py'\]/owns: []/" "$g"; rchk "A02-AC-1: a pinned node with an empty owns" 1 "P01: no owns"
adopt; sed -i 's/id: I01, name: core, track: done/id: I01, name: core, track: now/' "$g"; rchk "A02-AC-1: an imported node with a track other than done" 1 "I01: track must be done"
adopt; sed -i 's/id: P01, name: pin, track: done/id: P01, name: pin, track: later/' "$g"; rchk "A02-AC-1: a pinned node with a track other than done" 1 "P01: track must be done"
adopt; sed -i 's/P01-AC-2\*\* — two. \*Verify:\* superseded by X01-AC-1./P01-AC-2** — two. *Verify:* unpinned: needs a live database./' "$tmp/r/nodes/P01-pin.md"; rchk "A02-AC-1: a pinned node with an unpinned criterion" 1 "P01-AC-2" "unpinned"
adopt; sed -i 's/status: imported/status: pinned/' "$g"; rchk "A02-AC-1: an unpinned criterion on a node turned pinned" 1 "I01-AC-2" "unpinned"
adopt; sed -i 's/^`src\/util.py`, wrapped over/wrapped over/' "$tmp/r/nodes/I01-core.md"; rchk "A02-AC-1: an owns glob missing from the Owns paragraph" 1 "I01: owns glob src/util.py not in"
adopt; sed -i 's/^`src\/util.py`, wrapped over/\n`src\/util.py`, wrapped over/' "$tmp/r/nodes/I01-core.md"; rchk "A02-AC-1: an owns glob only after the Owns paragraph's blank line" 1 "I01: owns glob src/util.py not in"
adopt; sed -i 's/^`src\/util.py`, wrapped over/**Notes:** `src\/util.py`, wrapped over/' "$tmp/r/nodes/I01-core.md"; rchk "A02-AC-1: an owns glob only after the next **...:** line" 1 "I01: owns glob src/util.py not in"
adopt; sed -i "s/owns: \['tests\/\*\*\/new.py'\]/owns: ['tests\/**\/new.py', 'src\/util.py']/" "$g"; sed -i 's/^\*\*Owns:\*\* `tests\/\*\*\/new.py`/**Owns:** `tests\/**\/new.py`, `src\/util.py`/' "$tmp/r/nodes/X01-fresh.md"
rchk "A02-AC-1: one glob listed by two nodes" 1 "src/util.py listed by I01 and X01"
adopt; sed -i '/^gate:/,/^out_of_scope:/{/^out_of_scope:/!d}' "$g"; rchk "A02-AC-1: a missing gate with imported and pinned nodes" 1 "gate: required"
adopt; printf 'adoption: {areas: []}\nnodes: []\n' >"$g"; rchk "A02-AC-1: a missing gate when an adoption is present" 1 "gate: required"
adopt; sed -i 's/command: make test/command: ""/' "$g"; rchk "A02-AC-1: an empty gate.command" 1 "gate.command"
adopt; sed -i '/fail_pattern:/d' "$g"; rchk "A02-AC-1: a missing fail_pattern with a non-empty known_red" 1 "gate.fail_pattern"
adopt; sed -i "s/fail_pattern: '^FAIL'/fail_pattern: '('/" "$g"; rchk "A02-AC-1: an invalid fail_pattern" 1 "gate.fail_pattern"
adopt; sed -i "s/known_red: \['FAIL: flaky thing'\]/known_red: not a list/" "$g"; rchk "A02-AC-1: a known_red that is not a list" 1 "gate.known_red"
adopt; sed -i "s/known_red: \['FAIL: flaky thing'\]/known_red: [3]/" "$g"; rchk "A02-AC-1: a known_red entry that is not a string" 1 "gate.known_red"
adopt; sed -i 's/, reason: third party code//' "$g"; rchk "A02-AC-1: an out_of_scope entry without a reason" 1 "out_of_scope"
adopt; sed -i "s/reason: third party code/reason: ''/" "$g"; rchk "A02-AC-1: an out_of_scope entry with an empty reason" 1 "out_of_scope"
adopt; sed -i "s/{glob: 'vendor\/\*\*', reason/{reason/" "$g"; rchk "A02-AC-1: an out_of_scope entry without a glob" 1 "out_of_scope"
adopt; sed -i "s/, globs: \['src\/api\/\*\*'\]//" "$g"; rchk "A02-AC-1: an adoption area without globs" 1 "adoption" "api"
adopt; sed -i "s/globs: \['src\/api\/\*\*'\]/globs: []/" "$g"; rchk "A02-AC-1: an adoption area with an empty globs list" 1 "adoption" "api"
adopt; sed -i 's/name: api/name: scaffold/' "$g"; rchk "A02-AC-1: the reserved area name scaffold" 1 "adoption" "scaffold"
adopt; sed -i 's/name: api/name: plan/' "$g"; rchk "A02-AC-1: the reserved area name plan" 1 "adoption" "plan"
adopt; sed -i 's/name: web-ui/name: api/' "$g"; rchk "A02-AC-1: a duplicate area name" 1 "adoption" "duplicate" "api"
adopt; sed -i 's/name: web-ui/name: Web_UI/' "$g"; rchk "A02-AC-1: an area name that is not kebab-case" 1 "adoption" "Web_UI"

# ---- A02-AC-2: owns.py. API assumed (the spec names none):
#   owns.match(glob, path, files=None) -> bool: root-relative path against one glob; files = tracked paths, used only to
#     tell that a wildcard-free glob names a folder (any tracked path under glob + "/");
#   owns.regime_files(agents_text, files) -> list of the tracked paths that are the regime's own (spec files from the
#     **Spec files:** line of AGENTS.md's "Building a node" section, else SPEC.md, docs/graph.yaml, nodes/; plus AGENTS.md
#     and .noodlebot/roles.yaml).
cat >"$tmp/drv.py" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import owns
if sys.argv[2] == "match":
    print("yes" if owns.match(sys.argv[3], sys.argv[4], sys.argv[5:] or None) else "no")
else:
    print("\n".join(sorted(owns.regime_files(open(sys.argv[3]).read(), [l for l in sys.stdin.read().split("\n") if l]))))
EOF
# mt <name> <glob> <path> <yes|no> [tracked file]...
mt() {
	mname=$1; mg=$2; mp=$3; mw=$4; shift 4
	got=$(python3 -I "$tmp/drv.py" "$src" match "$mg" "$mp" "$@" 2>&1 | tail -n 1)
	if [ "$got" = "$mw" ]; then echo "PASS: $mname"; else echo "FAIL: $mname: glob '$mg' path '$mp' want $mw, got: $got"; fails=$((fails + 1)); fi
}
mt "A02-AC-2: * matches within one component" 'src/*.py' src/a.py yes
mt "A02-AC-2: * does not cross a slash" 'src/*.py' src/a/b.py no
mt "A02-AC-2: * alone is one component" '*' a.txt yes
mt "A02-AC-2: * alone does not match a deeper path" '*' a/b.txt no
mt "A02-AC-2: ** at the start matches zero components" '**/x.py' x.py yes
mt "A02-AC-2: ** at the start matches many components" '**/x.py' a/b/x.py yes
mt "A02-AC-2: ** at the start still needs the name" '**/x.py' a/y.py no
mt "A02-AC-2: ** in the middle matches zero components" 'src/**/x.py' src/x.py yes
mt "A02-AC-2: ** in the middle matches many components" 'src/**/x.py' src/a/b/x.py yes
mt "A02-AC-2: ** in the middle keeps the prefix" 'src/**/x.py' lib/a/x.py no
mt "A02-AC-2: ** at the end matches a deep path" 'src/**' src/a/b/c.py yes
mt "A02-AC-2: ** at the end matches a direct child" 'src/**' src/a.py yes
mt "A02-AC-2: ** at the end keeps the prefix" 'src/**' lib/a.py no
mt "A02-AC-2: a trailing / is the folder's files" 'docs/' docs/a.md yes
mt "A02-AC-2: a trailing / reaches every depth" 'docs/' docs/a/b/c.md yes
mt "A02-AC-2: a trailing / is root-relative" 'docs/' other/docs/a.md no
mt "A02-AC-2: a trailing / is not a name prefix" 'docs/' docsx/a.md no
mt "A02-AC-2: a literal path matches itself" src/util.py src/util.py yes
mt "A02-AC-2: a literal path is not a prefix match" src/util.py src/util.pyc no
mt "A02-AC-2: a literal path is not a folder when untracked-below" src/util.py src/util.py/x no src/util.py
mt "A02-AC-2: a wildcard-free glob naming a folder covers its files" src/core src/core/a.py yes src/core/a.py src/other.py
mt "A02-AC-2: a wildcard-free glob naming a folder covers deeper files" src/core src/core/deep/b.py yes src/core/a.py src/core/deep/b.py
mt "A02-AC-2: a wildcard-free glob naming a folder leaves its siblings" src/core src/coreX/a.py no src/core/a.py src/coreX/a.py
mt "A02-AC-2: a wildcard-free glob naming a file matches only the file" src/other.py src/other.py yes src/core/a.py src/other.py
cat >"$tmp/agents-with.md" <<'EOF'
# Agents

## Building a node

- **Spec files:** `docs/spec.md`, `plans/` (a trailing slash marks a folder)

## Traps

- **Spec files:** `ignored.md`
EOF
printf '# Agents\n\n## Building a node\n\nNo list here.\n' >"$tmp/agents-without.md"
tracked='SPEC.md
AGENTS.md
.noodlebot/roles.yaml
docs/graph.yaml
docs/spec.md
plans/a.md
plans/b/c.md
nodes/N01-x.md
src/x.py
ignored.md'
rt() {  # rt <name> <agents file> <want...>
	rname=$1; ragents=$2; shift 2
	got=$(printf '%s\n' "$tracked" | python3 -I "$tmp/drv.py" "$src" regime "$ragents" 2>&1 | LC_ALL=C sort)
	want=$(printf '%s\n' "$@" | LC_ALL=C sort)
	if [ "$got" = "$want" ]; then echo "PASS: $rname"; else echo "FAIL: $rname: want [$(echo $want)], got: $got"; fails=$((fails + 1)); fi
}
rt "A02-AC-2: the regime's own files come from the Spec files line, plus AGENTS.md and roles.yaml" "$tmp/agents-with.md" AGENTS.md .noodlebot/roles.yaml docs/spec.md plans/a.md plans/b/c.md
rt "A02-AC-2: without a Spec files line the default is SPEC.md, docs/graph.yaml and nodes/" "$tmp/agents-without.md" SPEC.md docs/graph.yaml nodes/N01-x.md AGENTS.md .noodlebot/roles.yaml

# ---- A02-AC-3: this repository's graph (none of the new fields) is still clean
repo=$(cd "$src/../../.." && pwd -P)
out=$(cd "$repo" && python3 -I "$src/check-regime.py" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "PROBLEMS 0"; then echo "PASS: A02-AC-3: this repository's graph reports PROBLEMS 0, exit 0"; else echo "FAIL: A02-AC-3: this repository's graph: exit $rc: $out"; fails=$((fails + 1)); fi
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all check-regime checks"

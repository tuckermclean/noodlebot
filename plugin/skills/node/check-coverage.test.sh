#!/bin/sh
# Tests check-coverage.py (A04): every tracked file is owned by one node, out of scope, in a pending area or the regime's own.
#   sh plugin/skills/node/check-coverage.test.sh   (make test)
# Fixtures: testdata/coverage/files (the tracked tree) and testdata/coverage/graphs/<name>.yaml (docs/graph.yaml variants),
# copied into a scratch repository with git init per case. Output asserted (fragments on ONE output line, plus the exit code
# and an exact "PROBLEMS <n>" line):
#   unowned file                 : the file path
#   file owned by two nodes      : the file path, both node IDs
#   owned and out_of_scope       : the file path, the node ID, the out_of_scope glob
#   owned and in a pending area  : the file path, the node ID, the area name
#   glob matching nothing        : the node ID, the glob
#   no ownership declared        : "no ownership declared" and "PROBLEMS 0"
set -u -f
src=$(cd "$(dirname "$0")" && pwd -P)
fx=$src/testdata/coverage
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
gt() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# mk <graph> [extra file]... : fresh repository $r from the fixture tree, graph variant installed, one commit
mk() {
	r=$tmp/r; rm -rf "$r"; cp -R "$fx/files" "$r"
	cp "$fx/graphs/$1.yaml" "$r/docs/graph.yaml"; shift
	for f in "$@"; do mkdir -p "$r/$(dirname "$f")"; echo x >"$r/$f"; done
	git -C "$r" init -q . && gt add -A && gt commit -qm "base"
}
# cov <name> <want exit> <want problems> [fragment]... [-- extra checker args]: one output line holds every fragment
cov() {
	cname=$1; cwant=$2; cn=$3; shift 3
	frs=; while [ $# -gt 0 ] && [ "$1" != -- ]; do frs="$frs
$1"; shift; done
	[ $# -gt 0 ] && shift
	out=$(python3 -I "$src/check-coverage.py" --root "$r" "$@" 2>&1); crc=$?
	ok=1
	[ "$crc" -eq "$cwant" ] || ok=0
	printf '%s\n' "$out" | grep -qx "PROBLEMS $cn" || ok=0
	line=$out
	oldifs=$IFS; IFS='
'
	for fr in $frs; do [ -n "$fr" ] && line=$(printf '%s\n' "$line" | grep -F -- "$fr"); done
	IFS=$oldifs
	[ -n "$line" ] || ok=0
	if [ "$ok" -eq 1 ]; then echo "PASS: $cname"; else echo "FAIL: $cname: want exit $cwant, PROBLEMS $cn, a line with [$(echo $frs)]; got exit $crc: $out"; fails=$((fails + 1)); fi
}

# ---- A04-AC-1: complete graphs report PROBLEMS 0
mk owned; cov "A04-AC-1: a fully owned repository has no problems" 0 0
mk oos vendor/lib.py vendor/deep/m.py; cov "A04-AC-1: files matched by out_of_scope are not problems" 0 0
mk pending src/api/h.py src/api/deep/i.py; cov "A04-AC-1: files in a pending adoption area are not problems" 0 0
mk owned; echo y >"$r/untracked.txt"; cov "A04-AC-1: an untracked file does not count" 0 0
mk owned; cov "A04-AC-1: the regime files (SPEC.md, AGENTS.md, docs/graph.yaml, nodes/*.md, roles.yaml) owned by no node are exempt" 0 0
mk owned docs/extra.md; printf '# Agents\n\n## Building a node\n\n- **Spec files:** `SPEC.md`, `docs/graph.yaml`, `nodes/`, `docs/extra.md`\n' >"$r/AGENTS.md"; gt add -A; gt commit -qm spec
cov "A04-AC-1: a file named on the Spec files line is exempt" 0 0
mk owned docs/extra.md; cov "A04-AC-1: a file not on the default spec list is not exempt" 1 1 docs/extra.md

# ---- A04-AC-1: --ref judges that commit's graph and files
mk owned; cp "$fx/graphs/ref-new.yaml" "$r/docs/graph.yaml"; echo x >"$r/src/z.py"; gt add -A; gt commit -qm "later"
cov "A04-AC-1: --ref judges the older commit (clean) while the working tree fails" 0 0 -- --ref HEAD~1
cov "A04-AC-1: the working tree itself fails (unowned files after the later commit)" 1 2 src/z.py
mk ref-new src/z.py; cp "$fx/graphs/owned.yaml" "$r/docs/graph.yaml"; gt rm -q --cached src/z.py; rm "$r/src/z.py"; gt add -A; gt commit -qm "fixed"
cov "A04-AC-1: --ref judges the older commit's files and graph (fails) while the working tree is clean" 1 2 src/z.py -- --ref HEAD~1
cov "A04-AC-1: the working tree is clean after the fix" 0 0

# ---- A04-AC-2: problems, one per line, exit 1
mk owned src/z.py; cov "A04-AC-2: a file no node owns is named" 1 1 src/z.py
mk two-owners; cov "A04-AC-2: a file two nodes own through different globs names the file and both nodes" 1 1 src/x.py A01 A02
mk owned-oos; cov "A04-AC-2: a file both owned and out of scope names the file, the node and the glob" 1 1 src/x.py A01 'src/x.*'
mk owned-pending; cov "A04-AC-2: a file both owned and in a pending area names the file, the node and the area" 1 1 src/x.py A01 api
mk imported-empty; cov "A04-AC-2: an imported node's glob matching nothing names the node and the glob" 1 1 A01 'src/gone/**'
mk planned; cov "A04-AC-2: a planned node not yet merged may name files it will create" 0 0
mk planned; echo x >>"$r/src/x.py"; gt commit -qam "A01 core: touch"; gt commit -q --allow-empty -m "A02 next: add the new thing"
cov "A04-AC-2: a planned node merged by an '<ID> <name>:' subject has its glob matching nothing named" 1 1 A02 'src/new/**'
mk planned; gt commit -q --allow-empty -m "A02 other: not this node"; gt commit -q --allow-empty -m "Spec: A02 next"
cov "A04-AC-2: other subjects do not mark a planned node merged" 0 0
mk planned; gt commit -q --allow-empty -m "A02 next: add the new thing"; gt tag merged; gt commit -q --allow-empty -m "later"
git -C "$r" reset -q --hard HEAD~2
cov "A04-AC-2: --ref judges the merged subjects at that commit (merged)" 1 1 A02 'src/new/**' -- --ref merged
cov "A04-AC-2: --ref before the merging subject (not merged)" 0 0 -- --ref HEAD

# ---- A04-AC-3: no ownership
mk none; cov "A04-AC-3: a graph without ownership prints no ownership declared and PROBLEMS 0" 0 0 "no ownership declared"
mk none src/z.py; cov "A04-AC-3: a graph without ownership ignores unowned files" 0 0 "no ownership declared"
root=$(cd "$src/../../.." && pwd -P)
out=$(python3 -I "$src/check-coverage.py" --root "$root" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "no ownership declared" && printf '%s\n' "$out" | grep -qx "PROBLEMS 0"; then echo "PASS: A04-AC-3: this repository's graph passes (no ownership declared, PROBLEMS 0)"; else echo "FAIL: A04-AC-3: this repository's graph: exit $rc: $out"; fails=$((fails + 1)); fi

# ---- review of c0d5bbb: quoted paths, pinned globs, --ref AGENTS.md, regime files owned twice
mk owned; mkdir -p "$r/src/core"; echo x >"$r/src/core/café.py"; echo x >"$r/src/core/q\"t.py"; echo x >"$r/src/core/b\\s.py"; gt add -A; gt commit -qm names
cov "A04-AC-1: unusual names (non-ASCII, quote, backslash) under an owned glob are matched as they are (working tree)" 0 0
cov "A04-AC-1: unusual names under an owned glob are matched as they are (--ref)" 0 0 -- --ref HEAD
mk owned src/naïve.py; cov "A04-AC-2: an unowned non-ASCII name is reported in its real form" 1 1 src/naïve.py
mk owned src/naïve.py; cov "A04-AC-2: an unowned non-ASCII name is reported in its real form (--ref)" 1 1 src/naïve.py -- --ref HEAD
mk pinned-empty; cov "A04-AC-2: a pinned node's glob matching nothing names the node and the glob" 1 1 A02 'src/gone/**'
mk owned docs/extra.md; printf '# Agents\n\n## Building a node\n\n- **Spec files:** `SPEC.md`, `docs/graph.yaml`, `nodes/`, `docs/extra.md`\n' >"$r/AGENTS.md"; gt add -A; gt commit -qm spec
cp "$fx/files/AGENTS.md" "$r/AGENTS.md"; gt add -A; gt commit -qm restore
cov "A04-AC-1: --ref reads AGENTS.md at that commit (Spec files line exempts docs/extra.md)" 0 0 -- --ref HEAD~1
cov "A04-AC-1: the working tree's AGENTS.md no longer exempts docs/extra.md" 1 1 docs/extra.md
mk regime-two-owners; cov "A04-AC-2: a regime file owned by two nodes is still named with both" 1 1 SPEC.md A01 A02
mk regime-oos; cov "A04-AC-2: a regime file owned and out of scope names the file, the node and the glob" 1 1 nodes/A01-core.md A01 'nodes/*.md'

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all check-coverage checks"

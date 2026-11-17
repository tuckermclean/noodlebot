#!/bin/sh
# Tests check-owns-diff.py (A05): a node's branch changes only its own files and its direct deps' files.
#   sh plugin/skills/node/check-owns-diff.test.sh   (make test)
# Fixtures: testdata/owns-diff/files (the tracked tree) and testdata/owns-diff/graphs/<name>.yaml (docs/graph.yaml variants).
# Node A03 owns src/c/**, depends on A01 (src/a/**, src/old/**); A02 (src/b/**) is not a dep, A04 (src/d/**) is not a dep.
# Every scratch repository has branch main and branch node; the node branch merges main in after its own commit
# (main touches src/d/x.txt and adds src/d/m.txt), and the checker runs as A03 main HEAD.
# Output asserted (fragments on ONE output line, plus the exit code):
#   not owned : "NOT OWNED <path> (owner: <ID or none>)"     unused own glob : "UNUSED <glob>"
#   globs used: a line naming each own glob and each dep glob  no ownership : "no ownership declared"
set -u -f
src=$(cd "$(dirname "$0")" && pwd -P)
fx=$src/testdata/owns-diff
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
gt() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# mk <main graph>: repository $r, one commit on main, branch node checked out
mk() {
	r=$tmp/r; rm -rf "$r"; cp -R "$fx/files" "$r"
	cp "$fx/graphs/$1.yaml" "$r/docs/graph.yaml"
	git -C "$r" init -q -b main . && gt add -A && gt commit -qm base && gt checkout -q -b node
}
# graph <name>: the branch's own version of the graph
graph() { cp "$fx/graphs/$1.yaml" "$r/docs/graph.yaml"; }
# fin: commit the branch's change, advance main (a non-dep's file changed, a file added), merge main into the branch
fin() {
	gt add -A && gt commit -qm "node change" --allow-empty
	gt checkout -q main; echo "main moved" >>"$r/src/d/x.txt"; echo m >"$r/src/d/m.txt"
	gt add -A && gt commit -qm "main moves"; gt checkout -q node
	gt merge -q --no-edit main >/dev/null 2>&1 || echo "FAIL: harness: merge of main failed"
}
# chk <name> <want exit> [fragment]... [-- <not wanted fragment>...]: runs the checker as A03 <from> <to> ($from, $to)
from=main; to=HEAD
chk() {
	cname=$1; cwant=$2; shift 2
	frs=; while [ $# -gt 0 ] && [ "$1" != -- ]; do frs="$frs
$1"; shift; done
	[ $# -gt 0 ] && shift
	nots=; for n in "$@"; do nots="$nots
$n"; done
	out=$(python3 -I "$src/check-owns-diff.py" --repo "$r" A03 "$from" "$to" 2>&1); crc=$?
	ok=1
	[ "$crc" -eq "$cwant" ] || ok=0
	[ -f "$src/check-owns-diff.py" ] || ok=0	# a missing checker exits 2 too: never a pass
	oldifs=$IFS; IFS='
'
	for fr in $frs; do [ -n "$fr" ] && { printf '%s\n' "$out" | grep -qF -- "$fr" || ok=0; }; done
	for n in $nots; do [ -n "$n" ] && { printf '%s\n' "$out" | grep -qF -- "$n" && ok=0; }; done
	IFS=$oldifs
	if [ "$ok" -eq 1 ]; then echo "PASS: $cname"; else echo "FAIL: $cname: want exit $cwant, lines [$(echo $frs)], not [$(echo $nots)]; got exit $crc: $out"; fails=$((fails + 1)); fi
}
edit() { echo "changed" >>"$r/$1"; }
add() { mkdir -p "$r/$(dirname "$1")"; echo "new $1" >"$r/$1"; }

# ---- own and dep files pass
mk base; edit src/c/x.txt; add src/c/new.txt; fin
chk "A05-AC-1: a node changing only its own files passes" 0 -- "NOT OWNED" "UNUSED"
mk base; edit src/a/x.txt; edit src/c/y.txt; fin
chk "A05-AC-1: a node also changing a dep's file passes" 0 -- "NOT OWNED" "UNUSED"
mk base; add src/a/deep/new.txt; edit src/c/x.txt; fin
chk "A05-AC-1: an added file in a folder a dep owns passes" 0 -- "NOT OWNED"

# ---- other nodes' files and unplaced files
mk base; edit src/d/y.txt; edit src/c/x.txt; fin
chk "A05-AC-1: a non-dep's file is NOT OWNED with its owner" 1 "NOT OWNED src/d/y.txt (owner: A04)" -- "NOT OWNED src/c/x.txt"
mk base; edit src/b/x.txt; fin
chk "A05-AC-1: a file of a node that is not a direct dep is NOT OWNED" 1 "NOT OWNED src/b/x.txt (owner: A02)"
mk base; add src/d/new.txt; fin
chk "A05-AC-1: an added file in a non-dep's folder is NOT OWNED with its owner" 1 "NOT OWNED src/d/new.txt (owner: A04)"
mk base; add src/zzz/new.txt; edit src/c/x.txt; fin
chk "A05-AC-1: an added file no own or dep glob matches is NOT OWNED (owner: none)" 1 "NOT OWNED src/zzz/new.txt (owner: none)"
mk base; edit misc/z.txt; fin
chk "A05-AC-1: a changed file no node owns is NOT OWNED (owner: none)" 1 "NOT OWNED misc/z.txt (owner: none)"

# ---- deleted and renamed files
mk base; gt rm -q src/d/y.txt; gt rm -q src/c/y.txt; fin
chk "A05-AC-1: a deleted file is judged by its old path (non-dep's NOT OWNED, own file passes)" 1 "NOT OWNED src/d/y.txt (owner: A04)" -- "NOT OWNED src/c/y.txt"
mk base; gt rm -q src/a/y.txt; gt rm -q src/c/y.txt; fin
chk "A05-AC-1: deleted files under an own and a dep glob pass" 0 -- "NOT OWNED"
mk base; gt mv src/c/x.txt src/d/moved.txt; fin
chk "A05-AC-1: a file renamed into a non-dep's folder is judged by its new path" 1 "NOT OWNED src/d/moved.txt (owner: A04)"
mk base; gt mv src/d/y.txt src/c/moved.txt; fin
chk "A05-AC-1: a file renamed out of a non-dep's folder is judged by its old path" 1 "NOT OWNED src/d/y.txt (owner: A04)"
mk base; gt mv src/c/x.txt src/a/moved.txt; fin
chk "A05-AC-1: a file renamed from an own folder to a dep's folder passes" 0 -- "NOT OWNED"

# ---- files merged in from main are not the node's
mk base; edit src/c/x.txt; fin
chk "A05-AC-1: files that came from main through the merge (src/d/x.txt, src/d/m.txt) are not judged" 0 -- "src/d/x.txt" "src/d/m.txt" "NOT OWNED"
mk base; fin
chk "A05-AC-1: a branch with nothing of its own passes though main's files differ" 0 -- "NOT OWNED"

# ---- deps are read at <from>
mk base; graph adddep; edit src/d/y.txt; fin
chk "A05-AC-1: a branch adding a dep to its own graph entry is judged with the deps at main (dep's file NOT OWNED)" 1 "NOT OWNED src/d/y.txt (owner: A04)"
mk base; graph rmdep; gt rm -q src/old/o.txt; fin
chk "A05-AC-1: a branch deleting a dep's files and removing that dep glob in the same branch passes (judged by the dep's globs at main)" 0 -- "NOT OWNED"

# ---- the regime's own files are exempt
mk base; echo x >>"$r/SPEC.md"; echo "# more" >>"$r/docs/graph.yaml"; echo x >>"$r/nodes/A03.md"; add nodes/A09-new.md; echo x >>"$r/AGENTS.md"; echo x >>"$r/.noodlebot/roles.yaml"; edit src/c/x.txt; fin
chk "A05-AC-1: changes to SPEC.md, docs/graph.yaml, nodes/, AGENTS.md and .noodlebot/roles.yaml are exempt" 0 -- "NOT OWNED"

# ---- an own glob matching nothing at <to>
mk base; graph unused; edit src/c/x.txt; fin
chk "A05-AC-1: an own glob matching no file at the head is UNUSED" 1 "UNUSED src/gone/**" -- "UNUSED src/c/**"

# ---- the globs used are printed
mk base; edit src/c/x.txt; fin
chk "A05-AC-1: the output names the own glob" 0 "src/c/**"
chk "A05-AC-1: the output names the dep's glob" 0 "src/a/**"
chk "A05-AC-1: the output names the dep's second glob" 0 "src/old/**" -- "src/b/**" "src/d/**"

# ---- no ownership
mk none; edit src/c/x.txt; add src/zzz/q.txt; fin
chk "A05-AC-1: a graph without ownership prints no ownership declared and exits 0" 0 "no ownership declared" -- "NOT OWNED"

# ---- git failure
mk base; edit src/c/x.txt; fin
to=nosuchcommit; chk "A05-AC-1: an unknown commit exits 2" 2; to=HEAD
from=nosuchcommit; chk "A05-AC-1: an unknown <from> exits 2" 2; from=main

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all check-owns-diff checks"

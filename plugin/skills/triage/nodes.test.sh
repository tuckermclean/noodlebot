#!/bin/sh
# Tests triage's nodes.py (open spec PRs, next free ID, clashes) and SKILL.md's ID rule (G01-AC-1..4).
#   sh plugin/skills/triage/nodes.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# Fake gh: `gh pr list` answers $GH_PRS (a JSON list of open PRs), or fails while $GH_FAIL exists.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/bin/sh
[ -e "$GH_FAIL" ] && exit 1
if [ "$1" = pr ] && [ "$2" = list ]; then cat "$GH_PRS"; exit 0; fi
exit 1
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_FAIL="$tmp/gh-fail" GH_PRS="$tmp/prs.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

row() { printf '  - {id: %s, track: now, name: %s, deps: [], summary: "x"}\n' "$1" "$2"; }
# graph <file> <id:name>...
graph() {
	f=$1; shift
	{ echo 'template: {headings: [Purpose, Tests, Changes, Gate, Risks]}'; echo 'nodes:'
	  for p in "$@"; do row "${p%%:*}" "${p#*:}"; done; } >"$f"
	for p in "$@"; do printf '# %s\n\n**Owns:** x\n' "$p" >"$(dirname "$f")/../nodes/${p%%:*}-${p#*:}.md"; done
}

# mkorigin <dir> <main nodes...>: bare origin with main; seed work tree at <dir>.seed
mkorigin() {
	d=$1; shift
	git init -q --bare "$d" && git -C "$d" symbolic-ref HEAD refs/heads/main
	git clone -q "$d" "$d.seed" 2>/dev/null
	git -C "$d.seed" checkout -q -b main
	mkdir -p "$d.seed/docs" "$d.seed/nodes"
	graph "$d.seed/docs/graph.yaml" "$@"
	git -C "$d.seed" add -A && git -C "$d.seed" commit -q -m "main"
	git -C "$d.seed" push -q origin main
}
# mkbranch <seed> <branch> <id:name>: a branch from the seed's current main adding one node
mkbranch() {
	git -C "$1" checkout -q -b "$2" main
	ids=$(sed -n 's/^  - {id: \([A-Z0-9]*\), .*name: \([a-z0-9-]*\),.*/\1:\2/p' "$1/docs/graph.yaml")
	# shellcheck disable=SC2086
	graph "$1/docs/graph.yaml" $ids "$3"
	git -C "$1" add -A && git -C "$1" commit -q -m "add $3"
	git -C "$1" push -q origin "$2"
	git -C "$1" checkout -q main
}
prs() { # prs <number:branch>...
	{ printf '['; sep=''
	  for p in "$@"; do
		printf '%s{"number":%s,"state":"OPEN","headRefName":"%s","author":{"login":"bot","is_bot":true}}' "$sep" "${p%%:*}" "${p#*:}"
		sep=','
	  done; printf ']\n'; } >"$GH_PRS"
}
# run <clone> [branch]: nodes.py in a fresh clone, optionally on a spec branch; sets out and rc
run() {
	rm -rf "$tmp/clone"
	git clone -q "$1" "$tmp/clone" 2>/dev/null
	git -C "$tmp/clone" fetch -q origin 2>/dev/null
	[ -z "${2:-}" ] || git -C "$tmp/clone" checkout -q -b "$2" "origin/$2"
	out=$(cd "$tmp/clone" && python3 -I "$src/nodes.py" 2>&1); rc=$?
}

# ---------- G01-AC-1: from main, two open spec PRs adding S03 and S04 ----------
O1="$tmp/o1.git"
mkorigin "$O1" S01:first S02:second
mkbranch "$O1.seed" spec/s03-alpha S03:alpha
mkbranch "$O1.seed" spec/s04-beta S04:beta
prs 41:spec/s03-alpha 42:spec/s04-beta
rm -f "$GH_FAIL"
run "$O1"
if printf '%s\n' "$out" | grep 'S03' | grep -q '41'; then ok "G01-AC-1: S03 listed with PR 41"; else bad "G01-AC-1: no line with S03 and PR number 41"; fi
if printf '%s\n' "$out" | grep 'S04' | grep -q '42'; then ok "G01-AC-1: S04 listed with PR 42"; else bad "G01-AC-1: no line with S04 and PR number 42"; fi
if printf '%s\n' "$out" | grep -i '^next free' | grep -q 'S05'; then ok "G01-AC-1: 'next free:' line gives S05"; else bad "G01-AC-1: no 'next free:' line with S05"; fi
if [ "$rc" -eq 0 ]; then ok "G01-AC-1: exit 0"; else bad "G01-AC-1: exit $rc"; fi

# ---------- G01-AC-2: on a spec branch whose S03 clashes with main's S03 ----------
O2="$tmp/o2.git"
mkorigin "$O2" S01:first S02:second
mkbranch "$O2.seed" spec/s03-alpha S03:alpha
mkbranch "$O2.seed" spec/s04-beta S04:beta
# main then gives S03 to another node
git -C "$O2.seed" checkout -q main
ids="S01:first S02:second S03:gamma"
# shellcheck disable=SC2086
graph "$O2.seed/docs/graph.yaml" $ids
git -C "$O2.seed" add -A && git -C "$O2.seed" commit -q -m "main takes S03" && git -C "$O2.seed" push -q origin main
prs 41:spec/s03-alpha 42:spec/s04-beta
run "$O2" spec/s03-alpha
if printf '%s\n' "$out" | grep -i 'clash' | grep -q 'S03'; then ok "G01-AC-2: S03 reported as a clash"; else bad "G01-AC-2: no clash line naming S03"; fi
if printf '%s\n' "$out" | grep -i 'clash' | grep -qi 'main'; then ok "G01-AC-2: the clash is said to be with main"; else bad "G01-AC-2: the clash line does not name main"; fi
if printf '%s\n' "$out" | grep 'S04' | grep -q '42'; then ok "G01-AC-2: the other PR (S04, 42) is listed"; else bad "G01-AC-2: other PR S04 / 42 not listed"; fi
if printf '%s\n' "$out" | grep '41' | grep -viq 'clash'; then bad "G01-AC-2: own PR 41 listed as another PR"; else ok "G01-AC-2: own PR 41 not listed as another PR"; fi
if printf '%s\n' "$out" | grep -i '^next free' | grep -q 'S05'; then ok "G01-AC-2: next free S is S05"; else bad "G01-AC-2: 'next free:' line lacks S05"; fi

# ---------- G01-AC-3: unknown IDs in open spec PRs ----------
check_unknown() { # check_unknown <label>
	if printf '%s\n' "$out" | grep -qi 'unknown'; then ok "G01-AC-3: $1: says the IDs in open spec PRs are unknown"; else bad "G01-AC-3: $1: does not say the IDs are unknown"; fi
	if printf '%s\n' "$out" | grep -qi '^next free'; then bad "G01-AC-3: $1: prints a next free line"; else ok "G01-AC-3: $1: no next free line"; fi
	if [ "$rc" -ne 0 ]; then ok "G01-AC-3: $1: exits non-zero"; else bad "G01-AC-3: $1: exits 0"; fi
}
prs 41:spec/s03-alpha 42:spec/s04-beta
: >"$GH_FAIL"
run "$O1"
check_unknown "PR list fails"
rm -f "$GH_FAIL"
prs 41:spec/s03-alpha 42:spec/s04-beta 43:spec/ghost
run "$O1"
check_unknown "a PR's graph unreadable"

# ---------- G01-AC-4: SKILL.md ----------
sk="$src/SKILL.md"
has() { grep -qi -e "$1" "$sk"; }
if has 'next free[`*]*:'; then ok "G01-AC-4: SKILL.md names the next free line"; else bad "G01-AC-4: SKILL.md does not mention 'next free'"; fi
if has 'nodes\.py' && has 'next free[`*]*:'; then ok "G01-AC-4: new node's ID comes from nodes.py"; else bad "G01-AC-4: SKILL.md does not tie the ID to nodes.py"; fi
if grep -i 'unknown\|cannot\|can.t\|fails' "$sk" | grep -qi 'without a PR\|no PR\|ends\|stop'; then ok "G01-AC-4: unknown IDs end the run without a PR"; else bad "G01-AC-4: no rule that unknown IDs end the run without a PR"; fi
if has '\-\-update <PR>'; then ok "G01-AC-4: --update <PR> described"; else bad "G01-AC-4: --update <PR> not described"; fi
sed -n '/\-\-update <PR>/,$p' "$sk" >"$tmp/upd.txt"
for w in 'merge' 'renumber' 'checker\|check-regime' 'push' 'comment'; do
	if grep -qi -e "$w" "$tmp/upd.txt"; then ok "G01-AC-4: --update text mentions $w"; else bad "G01-AC-4: --update text does not mention $w"; fi
done

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

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
# ---------- G01-AC-2 after a merge: both graph rows kept, in either order ----------
merged_case() { # merged_case <label> <id:name>...: the branch's graph holds these rows after merging main
	lbl=$1; shift
	O="$tmp/om-$lbl.git"
	mkorigin "$O" S01:first S02:second
	mkbranch "$O.seed" spec/s03-alpha S03:alpha
	mkbranch "$O.seed" spec/s04-beta S04:beta
	git -C "$O.seed" checkout -q main
	graph "$O.seed/docs/graph.yaml" S01:first S02:second S03:gamma
	git -C "$O.seed" add -A && git -C "$O.seed" commit -q -m "main takes S03" && git -C "$O.seed" push -q origin main
	git -C "$O.seed" checkout -q spec/s03-alpha
	git -C "$O.seed" merge -q -s ours --no-commit main >/dev/null 2>&1
	graph "$O.seed/docs/graph.yaml" "$@"
	git -C "$O.seed" add -A && git -C "$O.seed" commit -q -m "merge main, keep both rows" && git -C "$O.seed" push -q origin spec/s03-alpha
	git -C "$O.seed" checkout -q main
	prs 41:spec/s03-alpha 42:spec/s04-beta
	run "$O" spec/s03-alpha
	if printf '%s\n' "$out" | grep -i 'clash' | grep 'S03' | grep -qi 'main'; then ok "G01-AC-2: after a merge ($lbl): S03 still a clash with main"; else bad "G01-AC-2: after a merge ($lbl): no clash line naming S03 and main"; fi
	if printf '%s\n' "$out" | grep 'S04' | grep -q '42'; then ok "G01-AC-2: after a merge ($lbl): the other PR (S04, 42) is listed"; else bad "G01-AC-2: after a merge ($lbl): S04 / 42 not listed"; fi
	if printf '%s\n' "$out" | grep -i '^next free' | grep -q 'S05'; then ok "G01-AC-2: after a merge ($lbl): next free S is S05"; else bad "G01-AC-2: after a merge ($lbl): 'next free:' line lacks S05"; fi
}
merged_case alpha-first S01:first S02:second S03:alpha S03:gamma
merged_case gamma-first S01:first S02:second S03:gamma S03:alpha

# ---------- G01-AC-4: the --update section (from its heading) ----------
hl=$(grep -n '^#.*--update' "$sk" | head -n 1 | cut -d: -f1)
if [ -n "$hl" ]; then
	sed -n "$hl,\$p" "$sk" >"$tmp/upd2.txt"
	ok "G01-AC-4: a heading names --update"
else
	: >"$tmp/upd2.txt"; bad "G01-AC-4: no heading names --update"
fi
for w in 'merge' 'renumber' 'checker\|check-regime' 'push' 'comment'; do
	if grep -qi -e "$w" "$tmp/upd2.txt"; then ok "G01-AC-4: --update section mentions $w"; else bad "G01-AC-4: --update section does not mention $w"; fi
done


# ---------- G02-AC-5: the update procedure (section 4) has a resolution review before its push ----------
g02_d="$tmp/G02"; mkdir -p "$g02_d"
awk '/^## 4\./ { on = 1; next } /^## / && on { exit } on { print }' "$sk" >"$g02_d/sec4.txt"
g02_line() { awk -v re="$1" 'tolower($0) ~ re { print NR; exit }' "$g02_d/sec4.txt"; }
g02_win() { # g02_win <n> <ere>...: a window of n lines matches every ERE
	n=$1; shift; pats=$(printf '%s\n' "$@")
	awk -v n="$n" -v pats="$pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ L[NR] = tolower($0) }
		END { for (i = 1; i <= NR; i++) { w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
			good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
			if (good) exit 0 }
			exit 1 }' "$g02_d/sec4.txt"
}
g02_push=$(awk 'tolower($0) ~ /^[0-9]+\. *push/ { print NR; exit }' "$g02_d/sec4.txt")
g02_rv=$(g02_line 'new reviewer|fresh reviewer')
g02_hd=$(g02_line 'resolution review [(]')
if [ -n "$g02_push" ]; then ok "G02-AC-5: section 4 has a push step"; else bad "G02-AC-5: section 4 has no numbered push step"; fi
if [ -n "$g02_rv" ] && [ -n "$g02_push" ] && [ "$g02_rv" -lt "$g02_push" ]; then ok "G02-AC-5: a new reviewer is named before the push step"; else bad "G02-AC-5: no new reviewer named before the push step (${g02_rv:-none})"; fi
if g02_win 4 'merge commit' 'both parents'; then ok "G02-AC-5: the reviewer gets the merge commit and its diffs against both parents"; else bad "G02-AC-5: no merge commit with diffs against both parents"; fi
if [ -n "$g02_hd" ] && [ -n "$g02_push" ] && [ "$g02_hd" -lt "$g02_push" ]; then ok "G02-AC-5: the 'Resolution review (' heading is defined before the push step"; else bad "G02-AC-5: no 'Resolution review (' heading before the push step (${g02_hd:-none})"; fi
if g02_win 4 'resolution review [(]' 'comment' 'never an approval|not an approval|never approv|not approv'; then ok "G02-AC-5: the verdict is a comment, never an approval"; else bad "G02-AC-5: the verdict is not a comment, never an approval"; fi
if g02_win 5 'intent' 'both sides'; then ok "G02-AC-5: checks both sides' intent"; else bad "G02-AC-5: does not check both sides' intent"; fi
if g02_win 6 'test block' 'different nodes|other nodes|another node' 'names|state'; then ok "G02-AC-5: checks that test blocks of different nodes share no names or state"; else bad "G02-AC-5: no check on test blocks sharing names or state"; fi
if g02_win 6 'frozen' 'no .*(changed|removed|renamed)|not (been )?(changed|removed|renamed)|unchanged'; then ok "G02-AC-5: checks that no frozen test line changed"; else bad "G02-AC-5: no check that no frozen test line changed"; fi
if g02_win 5 'second' 'reject|request_changes' 'push(es)? nothing|nothing (is )?pushed' 'comment'; then ok "G02-AC-5: a second rejection pushes nothing and comments on the PR"; else bad "G02-AC-5: no rule that a second rejection pushes nothing and comments on the PR"; fi
if g02_win 4 'push' 'only after|until|before|approv' 'review'; then ok "G02-AC-5: nothing is pushed before the review approves"; else bad "G02-AC-5: no rule that nothing is pushed before the review approves"; fi


# ---------- G02 slice 3b (review3 findings 1, 4): checks tied to the numbered steps of section 4 ----------
g02b_steps="$g02_d/steps.txt"
tr -d '*' <"$g02_d/sec4.txt" | awk '
	function flush() { if (cur != "") print tolower(cur); cur = "" }
	/^[0-9]+\. / { flush(); n = $0; sub(/\..*/, "", n); t = $0; sub(/^[0-9]+\. */, "", t); cur = n "\t" t; next }
	/^[ \t]*$/ || /^#/ { flush(); next }
	cur != "" { sub(/^[ \t]+/, ""); cur = cur " " $0 }
	END { flush() }' >"$g02b_steps"
g02b_no() { awk -F'\t' -v re="$1" '$2 ~ re { print $1; exit }' "$g02b_steps"; }
g02b_rn=$(g02b_no 'resolution review'); g02b_pn=$(g02b_no '^push')
g02b_rt=$(awk -F'\t' -v n="${g02b_rn:-0}" '$1 == n { print $2 }' "$g02b_steps")
if [ -n "$g02b_rn" ] && [ -n "$g02b_pn" ] && [ "$g02b_rn" -lt "$g02b_pn" ]; then ok "G02-AC-5: the review step ($g02b_rn) precedes the push step ($g02b_pn)"; else bad "G02-AC-5: the review step must precede the push step (review ${g02b_rn:-none}, push ${g02b_pn:-none})"; fi
if printf '%s\n' "$g02b_rt" | grep -Eqi 'nothing is pushed until[^.]*approv|push(ed)? only after[^.]*approv'; then ok "G02-AC-5: the review step says nothing is pushed until it approves"; else bad "G02-AC-5: the review step lacks 'nothing is pushed until it approves'"; fi
if [ "$(printf '%s\n' "$g02b_rt" | grep -oi 'new reviewer' | wc -l)" -ge 2 ] && ! printf '%s\n' "$g02b_rt" | grep -Eqi 'earlier reviewer|same reviewer|previous reviewer|first reviewer|resume'; then ok "G02-AC-5: both rounds of the review use a new reviewer"; else bad "G02-AC-5: the second round must use a new reviewer too (not the earlier one)"; fi
if printf '%s\n' "$g02b_rt" | grep -Eqi -e '--dry-run' && printf '%s\n' "$g02b_rt" | grep -Eqi 'verdict' && printf '%s\n' "$g02b_rt" | grep -Eqi 'result\.md' && printf '%s\n' "$g02b_rt" | grep -Eqi 'not (be )?posted|not post|never posted|instead of post'; then ok "G02-AC-5: with --dry-run the review's verdict goes into result.md and is not posted on the PR"; else bad "G02-AC-5: the review step does not say that with --dry-run the verdict goes into result.md and is not posted"; fi


# ---------- G02 slice 3c (review3b findings 3, 4) ----------
g02c_rt=$(awk -F'\t' -v n="${g02b_rn:-0}" '$1 == n { print $2 }' "$g02b_steps")
g02c_sent=$(printf '%s\n' "$g02c_rt" | awk '{ i = index($0, "second rejection"); if (i) { t = substr($0, i); j = match(t, /\. /); if (j) t = substr(t, 1, j); print t } }')
if printf '%s\n' "$g02c_sent" | grep -Eqi 'push(es)? nothing|nothing is pushed' && printf '%s\n' "$g02c_sent" | grep -Eqi 'comment[^.]* pr'; then ok "G02-AC-5: the second-rejection sentence says nothing is pushed and comments on the PR"; else bad "G02-AC-5: the second-rejection sentence ('${g02c_sent:-none}') must say nothing is pushed and comment on the PR"; fi
g02c_pre=$(awk -F'\t' -v n="${g02b_rn:-0}" '$1 < n { print $2 } $1 == n { t = $2; i = index(t, "resolution review"); if (i) t = substr(t, 1, i - 1); print t }' "$g02b_steps" | sed -E -e 's/(never|no|not|without)[^.;]*push[a-z]*//g' -e 's/push(es)? nothing//g' -e 's/nothing is pushed//g')
if [ -n "$g02b_rn" ] && ! printf '%s\n' "$g02c_pre" | grep -Eqi 'push'; then ok "G02-AC-5: no step before the resolution review pushes"; else bad "G02-AC-5: a step before (or the start of) the review step ${g02b_rn:-none} pushes"; fi
# ---------- G02 slice 3d (review3c finding 3): checks that only tighten the AC-5 check above ----------
g02d_pv=$(printf '%s\n' "$g02b_rt" | sed 's/\. /.\n/g' | grep -F 'resolution review (')
if printf '%s\n' "$g02d_pv" | grep -Eq 'posted on the pr|gh pr comment'; then ok "G02-AC-5: the sentence with 'Resolution review (' says the verdict is posted on the PR"; else bad "G02-AC-5: the sentence with 'Resolution review (' ('${g02d_pv:-none}') must say the verdict is posted on the PR"; fi
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

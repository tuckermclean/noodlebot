#!/bin/sh
# Tests plugin/skills/node/SKILL.md: the update procedure (G02-AC-4), the resolution review (G02-AC-5, node skill),
# the tester step's scratch-folder rule (G02-AC-6).
#   sh plugin/skills/node/skill.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
sk="$src/SKILL.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
d="$tmp/G02"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# g02_section <heading-regex> <outfile>: the lines from the first "## " heading matching the regex up to the next "## " heading.
g02_section() {
	awk -v re="$1" '
		/^## / { if (on) exit; if (tolower($0) ~ re) on = 1 }
		on { print }' "$sk" >"$2"
}
# g02_win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive).
g02_win() {
	f=$1; n=$2; shift 2
	pats=$(printf '%s\n' "$@")
	awk -v n="$n" -v pats="$pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ L[NR] = tolower($0) }
		END {
			for (i = 1; i <= NR; i++) {
				w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
				good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$f"
}
# g02_line <file> <ere>: number of the first line matching (case-insensitive), empty if none.
g02_line() { awk -v re="$2" 'tolower($0) ~ re { print NR; exit }' "$1"; }
g02_check() { # g02_check <label> <file> <n> <ere>...
	lbl=$1; f=$2; n=$3; shift 3
	if g02_win "$f" "$n" "$@"; then ok "$lbl"; else bad "$lbl"; fi
}

if [ ! -f "$sk" ]; then bad "plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

# ---------- G02-AC-4: the update section ----------
u="$d/update.txt"
g02_section '^## .*--update' "$u"
if [ -s "$u" ]; then ok "G02-AC-4: a '## ' heading names --update"; else bad "G02-AC-4: no '## ' heading names --update"; fi
g02_check "G02-AC-4: update section describes --update <PR>" "$u" 3 '--update <pr>'
g02_check "G02-AC-4: update section describes --dry-run" "$u" 3 '--dry-run'
g02_check "G02-AC-4: --dry-run stops before the push and writes out/node/pr-<N>/result.md" "$u" 4 '--dry-run' 'out/node/pr-<n>/result\.md' 'push'
g02_check "G02-AC-4: merges origin/main into the PR's branch" "$u" 3 'merge' 'origin/main'
g02_check "G02-AC-4: the merge is a merge commit" "$u" 3 'merge commit'
g02_check "G02-AC-4: no rebase" "$u" 3 '(never|no|not|without)[^.]*rebase|rebase[^.]*(never|forbidden|not)'
g02_check "G02-AC-4: no force push" "$u" 3 '(never|no|not|without)[^.]*force|force[^.]*(never|forbidden|not)'
g02_check "G02-AC-4: a frozen test or fixture line that would change aborts the merge, pushes nothing, ends in QUESTION.md" "$u" 5 'frozen' 'abort' 'question\.md' 'nothing'
g02_check "G02-AC-4: a spec file that would change ends in QUESTION.md" "$u" 5 'spec file' 'question\.md'
g02_check "G02-AC-4: added test lines only keep appended test blocks apart" "$u" 4 'appended' 'apart|separat' 'test (file|line)|line'
g02_check "G02-AC-4: added test lines are listed in the PR comment" "$u" 4 'comment' 'added|each' 'test line|line'
g02_check "G02-AC-4: reruns make test and the PR's red targets" "$u" 4 'make test' 'red target'
g02_check "G02-AC-4: pushes only after the resolution review" "$u" 4 'push' 'resolution review' 'only|until|after|approv'
g02_check "G02-AC-4: comment holds each resolved file, the test results and the review's verdict" "$u" 5 'comment' 'resolved file|each file|each resolved' 'test result' 'verdict'
g02_check "G02-AC-4: reruns the whole-node fresh review only when the node's own code changed beyond keeping both sides" "$u" 4 'fresh review' 'only (when|if)|unless' 'beyond|own code'
g02_check "G02-AC-4: a failing test it cannot fix is a QUESTION.md with nothing pushed" "$u" 4 'fail' 'test' 'question\.md' 'nothing'
a=$(g02_line "$u" 'make test'); b=$(g02_line "$u" 'new reviewer'); c=$(g02_line "$u" 'resolved file|each file|each resolved')
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then ok "G02-AC-4: order: make test, then the new reviewer, then the comment"; else bad "G02-AC-4: order make test < new reviewer < comment not found (${a:-none}, ${b:-none}, ${c:-none})"; fi

# ---------- G02-AC-5: the resolution review (node skill) ----------
g02_check "G02-AC-5: a new reviewer reviews the resolution" "$u" 4 'resolution review|review of (the|every) (conflict )?resolution' 'new reviewer|fresh reviewer'
g02_check "G02-AC-5: the reviewer gets the merge commit and its diffs against both parents" "$u" 4 'merge commit' 'both parents' 'diff'
g02_check "G02-AC-5: it checks both sides' intent" "$u" 6 'intent' 'both sides'
g02_check "G02-AC-5: it checks that test blocks of different nodes share no names or state" "$u" 6 'test block' 'different nodes|other nodes|another node' 'names|state'
g02_check "G02-AC-5: it checks that no frozen test line changed" "$u" 6 'review' 'frozen test line|frozen line|frozen test' 'no .*(changed|removed|renamed)|not (been )?(changed|removed|renamed)|unchanged'
g02_check "G02-AC-5: nothing is pushed before the review approves" "$u" 5 'review' 'approv' 'push'
g02_check "G02-AC-5: the verdict is posted on the PR headed 'Resolution review (<verdict>)'" "$u" 4 'resolution review \(' 'verdict'
g02_check "G02-AC-5: the review is a comment, never an approval" "$u" 5 'resolution review' 'comment' 'never an approval|not an approval|never approv|not approv'
g02_check "G02-AC-5: a second rejection pushes nothing and ends with QUESTION.md" "$u" 5 'second' 'reject|request_changes' 'nothing' 'question\.md'
s6="$d/step6.txt"; g02_section '^## 6\.' "$s6"
if [ -s "$s6" ]; then ok "G02-AC-5: step 6 (Pull request) found"; else bad "G02-AC-5: step 6 (Pull request) not found"; fi
g02_check "G02-AC-5: the merge of origin/main before the final CI run gets the resolution review" "$s6" 6 'origin/main' 'resolution review|resolution.*new reviewer|new reviewer.*resolution'

# ---------- G02-AC-6: the tester step's scratch-folder rule ----------
s2="$d/step2.txt"; g02_section '^## 2\.' "$s2"
if [ -s "$s2" ]; then ok "G02-AC-6: step 2 (RED) found"; else bad "G02-AC-6: step 2 (RED) not found"; fi
g02_check "G02-AC-6: a test block appended to a shared test file keeps its scratch paths under a folder named after its node" "$s2" 4 'append' 'shared' 'scratch' 'folder|director' 'named after|<id>'
g02_check "G02-AC-6: the rule names what the scratch paths are (folders, remotes, state, fake binaries)" "$s2" 4 'scratch' 'remote|state|fake'

# ---------- G02-AC-4: the skill names no repository ----------
# Allowed: the plugin's own `noodlebot:` agents and command, `.noodlebot/` config. Not allowed: an owner or a repository name.
sed -e 's/noodlebot:/PLUGIN:/g' -e 's#\.noodlebot/#.CONF/#g' "$sk" >"$d/skill.stripped"
if grep -qi 'tuckermclean' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md names an owner (tuckermclean)"; else ok "G02-AC-4: SKILL.md names no owner"; fi
if grep -qi 'themonolith\|noodlebot' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md names a repository (noodlebot / themonolith)"; else ok "G02-AC-4: SKILL.md names no repository outside the plugin's own names"; fi
if grep -Eqi -e '--repo[ =]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|github\.com[:/]|git@github' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md has a repository slug or URL"; else ok "G02-AC-4: SKILL.md has no repository slug or URL"; fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }

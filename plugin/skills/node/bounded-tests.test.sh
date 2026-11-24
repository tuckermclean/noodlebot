#!/bin/sh
# Tests D18-AC-1, D18-AC-2, D18-AC-3: every session is told to keep its local test runs small.
#   D18-AC-1  plugin/skills/node/SKILL.md and plugin/agents/{tester,implementer,reviewer}.md
#   D18-AC-2  AGENTS.md (the **Tests:** bullet) and .claude/agents/noodlebot-{tester,implementer,reviewer}.md
#   D18-AC-3  plugin/skills/adopt/SKILL.md (its AGENTS.md draft)
# Each file says the bounded-run rule in ONE paragraph or bullet: the first one holding the words "scratch copy" (a
# unit runs from its first line to the next blank line, heading or list item). Every check reads that unit only, not
# the file; a file with no such unit fails each of its checks. A unit is flattened (emphasis and backticks removed,
# lower-cased) and cut into sentences at ". "; a check passes when ONE sentence matches every pattern of it, and a
# pattern that starts with "!" must not match that sentence.
# The rule of a plugin file, for each file: bounded workers (the bound AGENTS.md names, else at most two); one test
# runner at a time; never a whole suite with its cache off; a script that repeats the tests applies each mutant in a
# scratch copy of the tree (outside the node's own worktree, removed after the sweep), never in the node's own
# worktree, one run at a time, then checks the worktree is clean (git status). Of this repository's files the bound
# is TEST_JOBS=2 and the runner is one test file at a time. A unit that has a mutant applied in the worktree and
# restored by a trap or on exit fails; so does a unit that names a repository or a forge.
#   sh plugin/skills/node/bounded-tests.test.sh   (make test)
# D18_ROOT (default: this checkout) names the tree whose files are read; the test only reads.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${D18_ROOT:-$(cd "$src/../../.." && pwd -P)}
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# d_unit <file> <out>: the first paragraph or bullet of the file that holds "scratch copy" (empty out if none).
d_unit() {
	: >"$2"
	[ -f "$1" ] || return 0
	awk '
		function flush() { if (!done && u != "" && tolower(u) ~ /scratch copy/) { printf "%s", u; done = 1 } u = "" }
		/^[ \t]*$/ || /^#/ || /^[ \t]*([-*+]|[0-9]+[.]) / { flush() }
		/^[ \t]*$/ { next }
		{ u = u $0 "\n" }
		END { flush() }' "$1" >"$2"
}
# d_adopt <file> <out>: the AGENTS.md draft bullet of the adopt skill, up to the next top-level bold bullet.
d_adopt() {
	: >"$2"
	[ -f "$1" ] || return 0
	awk '!on && /^- \*\*`AGENTS[.]md`\*\*/ { on = 1; print; next } on && /^- \*\*/ { exit } on { print }' "$1" >"$2"
}
# d_sen <label> <unit> <ere>...: one sentence of the unit matches every ERE (a leading "!" negates). An empty unit fails.
d_sen() {
	s_l=$1; s_f=$2; shift 2
	printf '%s\n' "$@" >"$tmp/pats"
	if [ -s "$s_f" ] && awk '
		NR == FNR { P[++k] = $0; next }
		{ gsub(/[*`]/, ""); gsub(/’/, "\047"); t = t " " tolower($0) }
		END {
			t = t " "
			gsub(/e[.]g[.]/, "for example", t); gsub(/i[.]e[.]/, "that is", t)
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				good = 1
				for (p = 1; p <= k; p++) {
					if (substr(P[p], 1, 1) == "!") { if (s ~ substr(P[p], 2)) { good = 0; break } }
					else if (s !~ P[p]) { good = 0; break }
				}
				if (good) exit 0
			}
			exit 1 }' "$tmp/pats" "$s_f"; then ok "$s_l"; else bad "$s_l"; fi
}
# d_notrap <label> <unit>: no sentence of the unit has a mutant applied in the worktree and restored by a trap or on
# exit (a sentence that says never, not, no, without, instead of or rather than about it is the rule's own warning).
d_notrap() {
	if [ ! -s "$2" ]; then bad "$1 (the rule is not found)"; return; fi
	if awk '
		{ gsub(/[*`]/, ""); gsub(/’/, "\047"); t = t " " tolower($0) }
		END {
			t = t " "
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				gsub(/never in the node.s own worktree/, "", s)
				if (s ~ /mutant|mutat/ && s ~ /trap|restor|on exit/ && s !~ /(^|[^a-z])(never|not|no|nor|without|cannot)([^a-z]|$)|instead of|rather than/) exit 1
			}
			exit 0 }' "$2"; then ok "$1"; else bad "$1"; fi
}
# d_agnostic <label> <unit>: the rule names no repository and no forge.
d_agnostic() {
	if [ ! -s "$2" ]; then bad "$1 (the rule is not found)"; return; fi
	if grep -i -E 'github|gitlab|gitea|bitbucket|noodlebot|claude code|owner/name' "$2" >/dev/null; then bad "$1"; else ok "$1"; fi
}

# d_rule <AC> <who> <unit> <bound-kind> <runner-kind> <all>: the checks of one file's rule.
#   bound-kind: plugin (bounded workers: the bound AGENTS.md names, else at most two) | repo (TEST_JOBS=2 for the quick gate)
#   runner-kind: plugin (one test runner at a time) | repo (one test file at a time)
#   all: yes (every clause) | pins (bound, one file at a time, the two pinned phrases and no trap only)
d_rule() {
	ac=$1; who=$2; u=$3; bk=$4; rk=$5; all=$6
	if [ -s "$u" ]; then ok "$ac: $who: the bounded-run rule is found (a paragraph or bullet with the words scratch copy)"
	else bad "$ac: $who: the bounded-run rule is not found (no paragraph or bullet with the words scratch copy)"; fi
	if [ $bk = plugin ]; then
		d_sen "$ac: $who: a local test run uses bounded workers, the bound AGENTS.md names, else at most two" "$u" \
			'(^|[^a-z])bounded workers?' 'agents[.]md' 'at most (two|2)' '!(never|not) [a-z ]*bounded' '!more than (two|2)'
	else
		d_sen "$ac: $who: the bound of the quick gate is TEST_JOBS=2" "$u" \
			'test_jobs=2([^0-9]|$)' 'quick gate' '!(never|not) [a-z ]*test_jobs'
	fi
	if [ $rk = plugin ]; then
		d_sen "$ac: $who: one test runner at a time" "$u" \
			'one (test )?runner at a time' '!more than one' '!(never|not) (run |runs |use |uses )?one'
	else
		d_sen "$ac: $who: one test file at a time" "$u" \
			'one test file at a time' '!more than one' '!(never|not) (run |runs |use |uses )?one'
	fi
	if [ $all = yes ]; then
		d_sen "$ac: $who: never a whole suite with its cache off" "$u" \
			'never [a-z ]*whole suite' 'cache (is |turned |switched )?(off|disabled)' '!(always|may|can) [a-z ]*whole suite'
	fi
	d_sen "$ac: $who: a script that repeats the tests applies each mutant in a scratch copy of the tree" "$u" \
		'script|sweep|repeat' 'applies|apply|applied' 'each mutant|every mutant|a mutant|mutants' 'in a scratch copy of the tree' \
		'!(never|not) (apply|applies|applied|run|runs) [a-z ]*scratch copy'
	d_sen "$ac: $who: the mutant is applied never in the node's own worktree" "$u" \
		'mutant' "never in the node's own worktree" '!(not|never) never'
	if [ $all = yes ]; then
		d_sen "$ac: $who: the scratch copy is outside the node's worktree and removed after the sweep" "$u" \
			'scratch copy' 'outside' 'worktree' 'remov|delet' 'after the sweep|after it|when (it|the sweep)' '!(not|never) (remov|delet)'
		d_sen "$ac: $who: the script runs one run at a time" "$u" \
			'script|sweep|mutant' 'one [a-z ]*run at a time' '!more than one' '!(not|never) (run |runs )?one'
		d_sen "$ac: $who: the worktree is checked clean (git status) after the sweep" "$u" \
			'git status' 'clean' 'after' '!(no|not|without|skip) [a-z ]*(git status|check)'
	fi
	d_notrap "$ac: $who: no mutant is applied in the worktree and restored by a trap or on exit" "$u"
}

for p in "SKILL.md|plugin/skills/node/SKILL.md" "plugin tester agent|plugin/agents/tester.md" \
	"plugin implementer agent|plugin/agents/implementer.md" "plugin reviewer agent|plugin/agents/reviewer.md"; do
	who=${p%%|*}; f=$root/${p#*|}; k=$(echo "$who" | tr -c 'A-Za-z0-9\n' '_')
	if [ ! -f "$f" ]; then bad "D18-AC-1: $who: ${p#*|} is missing"; continue; fi
	d_unit "$f" "$tmp/$k.unit"
	d_rule D18-AC-1 "$who" "$tmp/$k.unit" plugin plugin yes
	d_agnostic "D18-AC-1: $who: the rule names no repository and no forge" "$tmp/$k.unit"
	if grep -i -E 'github[.]com|claude code' "$f" >/dev/null; then bad "D18-AC-1: $who: the file names a forge URL or Claude Code"
	else ok "D18-AC-1: $who: the file names no forge URL and no Claude Code"; fi
done

for p in "noodlebot-tester agent|.claude/agents/noodlebot-tester.md" "noodlebot-implementer agent|.claude/agents/noodlebot-implementer.md" \
	"noodlebot-reviewer agent|.claude/agents/noodlebot-reviewer.md"; do
	who=${p%%|*}; f=$root/${p#*|}; k=$(echo "$who" | tr -c 'A-Za-z0-9\n' '_')
	if [ ! -f "$f" ]; then bad "D18-AC-2: $who: ${p#*|} is missing"; continue; fi
	d_unit "$f" "$tmp/$k.unit"
	d_rule D18-AC-2 "$who" "$tmp/$k.unit" repo repo yes
done

# AGENTS.md: the unit must be the **Tests:** bullet.
d_unit "$root/AGENTS.md" "$tmp/agents.unit"
if [ -s "$tmp/agents.unit" ] && head -n 1 "$tmp/agents.unit" | grep -E '^- \*\*Tests:\*\*' >/dev/null; then
	ok "D18-AC-2: AGENTS.md: the bounded-run rule is in the Tests: bullet"
else bad "D18-AC-2: AGENTS.md: the bounded-run rule is not in the Tests: bullet"; : >"$tmp/agents.unit"; fi
d_rule D18-AC-2 "AGENTS.md Tests:" "$tmp/agents.unit" repo repo pins

# The adopt skill's AGENTS.md draft: a line for the test runner's bounded-worker flags, the adopted repository's own fact.
d_adopt "$root/plugin/skills/adopt/SKILL.md" "$tmp/adopt.unit"
if [ -s "$tmp/adopt.unit" ]; then ok "D18-AC-3: adopt SKILL.md: the AGENTS.md draft bullet is found"
else bad "D18-AC-3: adopt SKILL.md: the AGENTS.md draft bullet is not found"; fi
d_sen "D18-AC-3: adopt SKILL.md: the AGENTS.md draft names the test runner's bounded-worker flags" "$tmp/adopt.unit" \
	'test runner' 'bounded[- ]worker' 'flags' '!(not|never|no) [a-z ]*(bounded|flags)' '!no line'
d_sen "D18-AC-3: adopt SKILL.md: the flags are the adopted repository's own fact, taken from the repository" "$tmp/adopt.unit" \
	'bounded[- ]worker' 'flags' "(adopted repository.s own|repository.s own|taken from the (adopted )?repository|from the repository)" \
	'!(not|never) taken'

# Review fix: for the three repository agent files, the rule also says one test runner at a time, and "one test file at a time"
# belongs to the script that repeats the tests, never to the sentence that bounds the quick gate with TEST_JOBS=2.
# d_nosen <label> <unit> <ere>...: no sentence of the unit matches every ERE (an empty unit fails).
d_nosen() {
	s_l=$1; s_f=$2; shift 2
	printf '%s\n' "$@" >"$tmp/pats"
	if [ -s "$s_f" ] && awk '
		NR == FNR { P[++k] = $0; next }
		{ gsub(/[*`]/, ""); gsub(/’/, "\047"); t = t " " tolower($0) }
		END {
			t = t " "
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				all = 1
				for (p = 1; p <= k; p++) if (s !~ P[p]) { all = 0; break }
				if (all) exit 1
			}
			exit 0 }' "$tmp/pats" "$s_f"; then ok "$s_l"; else bad "$s_l"; fi
}
for p in "noodlebot-tester agent|.claude/agents/noodlebot-tester.md" "noodlebot-implementer agent|.claude/agents/noodlebot-implementer.md" \
	"noodlebot-reviewer agent|.claude/agents/noodlebot-reviewer.md"; do
	who=${p%%|*}; k=$(echo "$who" | tr -c 'A-Za-z0-9\n' '_')
	[ -f "$root/${p#*|}" ] || continue
	d_sen "D18-AC-2: $who: one test runner at a time" "$tmp/$k.unit" \
		'one (test )?runner at a time' '!more than one' '!(never|not) (run |runs |use |uses )?one'
	d_sen "D18-AC-2: $who: one test file at a time is said of the script that repeats the tests (the sweep's sentence)" "$tmp/$k.unit" \
		'script|sweep|repeat' 'mutant' 'one test file at a time' '!more than one'
	d_nosen "D18-AC-2: $who: no sentence puts one test file at a time together with TEST_JOBS=2" "$tmp/$k.unit" \
		'one test file at a time' 'test_jobs=2'
done
d_sen "D18-AC-2: AGENTS.md Tests: one test file at a time is said of the script that repeats the tests (the sweep's sentence)" "$tmp/agents.unit" \
	'script|sweep|repeat' 'mutant' 'one test file at a time' '!more than one'

# Review fix: d_notrap exempts any sentence with a negation word anywhere. This stricter check lets a negation count only
# when it directly precedes the action it forbids ("never apply a mutant in the worktree and restore it by a trap").
# d_notrap2 <label> <unit>: no sentence has a mutant applied or put in the worktree together with a trap, a restore or on exit.
d_notrap2() {
	if [ ! -s "$2" ]; then bad "$1 (the rule is not found)"; return; fi
	if awk '
		{ gsub(/[*`]/, ""); gsub(/’/, "\047"); t = t " " tolower($0) }
		END {
			t = t " "
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				gsub(/never in the node.s own worktree/, "", s)
				gsub(/outside the node.s (own )?worktree/, "", s)
				gsub(/(never|not|no|nor|cannot|don.t|do not) (to )?(be )?(appl|put|writ|restor)[a-z]*/, "", s)
				if (s ~ /(appl|put|writ)[a-z]* [a-z ]*mutant[a-z ]* in the (node.s )?(own )?worktree|mutant[a-z ]* (appl|put|writ)[a-z]* in the (node.s )?(own )?worktree/ && s ~ /trap|restor|on exit/) exit 1
			}
			exit 0 }' "$2"; then ok "$1"; else bad "$1"; fi
}
for p in "SKILL.md|plugin/skills/node/SKILL.md|D18-AC-1" "plugin tester agent|plugin/agents/tester.md|D18-AC-1" \
	"plugin implementer agent|plugin/agents/implementer.md|D18-AC-1" "plugin reviewer agent|plugin/agents/reviewer.md|D18-AC-1" \
	"noodlebot-tester agent|.claude/agents/noodlebot-tester.md|D18-AC-2" "noodlebot-implementer agent|.claude/agents/noodlebot-implementer.md|D18-AC-2" \
	"noodlebot-reviewer agent|.claude/agents/noodlebot-reviewer.md|D18-AC-2"; do
	who=${p%%|*}; r=${p#*|}; f=$root/${r%%|*}; ac=${r#*|}; k=$(echo "$who" | tr -c 'A-Za-z0-9\n' '_')
	[ -f "$f" ] || continue
	d_unit "$f" "$tmp/$k.unit2"
	d_notrap2 "$ac: $who: no sentence applies a mutant in the worktree and restores it by a trap or on exit" "$tmp/$k.unit2"
done
d_notrap2 "D18-AC-2: AGENTS.md Tests: no sentence applies a mutant in the worktree and restores it by a trap or on exit" "$tmp/agents.unit"

echo "$fails failed"
[ "$fails" = 0 ]

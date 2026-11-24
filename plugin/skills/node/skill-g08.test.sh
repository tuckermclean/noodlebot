#!/bin/sh
# Tests G08-AC-3: a red CI run of gate.command is judged from its job log, read with `<forge> ci logs --run <id>`,
# stripped and matched by the gate's pass condition, with each failing line and its known_red entry in the evidence
# next to the run URL; a log the forge will not give (exit 3) does not pass the run but goes to the owner with the run
# URL, and the run is not recorded as red only with known_red failures; a green run needs no log.
# Said in three places, each checked in its own scope, one statement within one sentence per case:
#   SKILL.md          step 5 (from "## 5." up to "## 6.")
#   reviewer.md       "What to check" item 6 (GREEN, the CI run and the gate's pass condition), up to item 7
#   the node update   the bullet that starts "- Follow @CMD@" (where the quick gate's rule and the CI run are said),
#   template          up to the bullet "- Never change a frozen test"
# A sentence is cut at ". " (emphasis and backticks removed, lower-cased); a case passes when one sentence of the scope
# matches every pattern; a pattern starting with "!" must not match that sentence. The step-5 rule A10 added (strip
# what CI adds; the evidence lists each failing line as stripped) already stands there, so each case ties the clause
# to the CI log (`ci logs`, the job log, the red run) to ask for new text.
#   sh plugin/skills/node/skill-g08.test.sh   (make test)
# G08_ROOT (default: this checkout) names the tree whose files are read; the test only reads.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${G08_ROOT:-$(cd "$src/../../.." && pwd -P)}
sk="$root/plugin/skills/node/SKILL.md"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
d="$tmp/G08"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# g8_sen <label> <file> <ere>...: one sentence of the file matches every ERE (a leading "!" negates). An empty or
# missing file fails.
g8_sen() {
	s_l=$1; s_f=$2; shift 2
	s_pats=$(printf '%s\n' "$@")
	if [ -s "$s_f" ] && awk -v pats="$s_pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ gsub(/[*`]/, ""); t = t " " tolower($0) }
		END {
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
			exit 1 }' "$s_f"; then ok "$s_l"; else bad "$s_l"; fi
}
# g8_unit <file> <start-ere> <stop-ere> <out>: from the first line matching the start up to (not including) the next
# line matching the stop.
g8_unit() { awk -v re="$2" -v stop="$3" '!on && $0 ~ re { on = 1; print; next } on && $0 ~ stop { exit } on { print }' "$1" >"$4"; }

if [ ! -f "$sk" ]; then bad "G08-AC-3: plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

awk '/^## / { if (on) exit; if (tolower($0) ~ /^## 5[.]/) on = 1 } on { print }' "$sk" >"$d/skill.md"
if [ -f "$root/plugin/agents/reviewer.md" ]; then
	g8_unit "$root/plugin/agents/reviewer.md" '^6[.] ' '^[0-9]+[.] |^#' "$d/reviewer.md"
else : >"$d/reviewer.md"; fi
if [ -f "$root/scheduler/unattended-node-update.md" ]; then
	g8_unit "$root/scheduler/unattended-node-update.md" '^- Follow @CMD@' '^- Never change a frozen' "$d/template.md"
else : >"$d/template.md"; fi

for p in "SKILL.md step 5|skill" "the reviewer agent's item 6 (GREEN)|reviewer" "unattended-node-update.md (the Follow bullet)|template"; do
	who=${p%%|*}; k=${p#*|}; f="$d/$k.md"
	if [ -s "$f" ]; then ok "G08-AC-3: $who: the text is found"; else bad "G08-AC-3: $who: the text is not found"; fi
	g8_sen "G08-AC-3: $who: a red CI run of gate.command is judged from its job log" "$f" \
		'red' 'ci run' 'gate[.]command' 'job log' 'judg' '!(never|not) (be )?judged' '!without [a-z ]*log'
	g8_sen "G08-AC-3: $who: the job log is read with <forge> ci logs --run <id>" "$f" \
		'job log|jobs. logs?' 'read|fetch' 'ci logs --run' '!(ignore|not read|never read|without read|not fetch)'
	g8_sen "G08-AC-3: $who: the log read with ci logs is stripped" "$f" \
		'ci logs' 'strip' '!(not|never) strip' '!without strip'
	g8_sen "G08-AC-3: $who: the log read with ci logs is judged by the gate's pass condition" "$f" \
		'ci logs' 'match[a-z]* .*(pass condition|that condition)|judg[a-z]* [a-z ]*by (the gate.s pass condition|that condition)' '!(not|never) match'
	g8_sen "G08-AC-3: $who: the evidence has each failing line of the red CI run with its known_red entry" "$f" \
		'evidence' 'each failing line' 'known_red' 'entry' 'red ci run|red run|job log|ci logs'
	g8_sen "G08-AC-3: $who: the failing lines and their known_red entries are in the evidence next to the run URL" "$f" \
		'evidence' 'failing line' 'known_red' '(next to|beside|alongside|together with) the run url'
	g8_sen "G08-AC-3: $who: a log the forge will not give (exit 3) does not pass the run" "$f" \
		'log' 'forge' 'exit 3' 'will not (give|provide|serve|return)|refus|(does|do) not (give|provide|serve|return)|cannot (give|provide|serve|return)|not given' 'not pass|never pass|cannot pass|fails the run' 'the run'
	g8_sen "G08-AC-3: $who: a log the forge will not give goes to the owner" "$f" \
		'log' 'will not (give|provide|serve|return)|refus|(does|do) not (give|provide|serve|return)|cannot (give|provide|serve|return)|not given' 'owner' '(ask|question)' '!(not|never|without) (ask|write|put|send|report|raise)'
	g8_sen "G08-AC-3: $who: a log the forge will not give goes to the owner with the run URL" "$f" \
		'log' 'will not (give|provide|serve|return)|refus|(does|do) not (give|provide|serve|return)|cannot (give|provide|serve|return)|not given' 'owner' 'run url' '!(without|omits?|no) (the )?run url' '!(not|never|without) (ask|write|put|send|report|raise)'
	g8_sen "G08-AC-3: $who: the run is not recorded as red only with known_red failures" "$f" \
		'run' 'red only with known_red failures' 'not record|never record|neither record|instead of record|rather than record'
	g8_sen "G08-AC-3: $who: a green run needs no log" "$f" \
		'green' 'needs no (job )?log|no (job )?log is (needed|read|required)|not need [a-z ]*log|log is not (needed|read|required)|without [a-z ]*log'
done
g8_sen "G08-AC-3: SKILL.md step 5: the owner is asked as step 7 says" "$d/skill.md" \
	'log' 'will not (give|provide|serve|return)|refus|(does|do) not (give|provide|serve|return)|cannot (give|provide|serve|return)|not given' 'owner' 'step 7' '!(not|never|without) (ask|write|put|send|report|raise)'
g8_sen "G08-AC-3: the template: the owner is asked through QUESTION.md" "$d/template.md" \
	'log' 'will not (give|provide|serve|return)|refus|(does|do) not (give|provide|serve|return)|cannot (give|provide|serve|return)|not given' 'owner' 'question[.]md'

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

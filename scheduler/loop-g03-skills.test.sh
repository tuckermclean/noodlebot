#!/bin/sh
# G03-AC-7, G03-AC-8: the text of the node and triage skills describes the --feedback procedure (plain greps; no loop runs).
#   sh scheduler/loop-g03-skills.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# fbsec <skill file> <out>: the text of the skill's --feedback description: from the first heading or paragraph that
# names --feedback to the next heading of the same or a higher level (the heading's own level); a skill that has none
# gives an empty file.
fbsec() {
	awk '
		function lvl(s,   m) { m = s; sub(/[^#].*/, "", m); return length(m) }
		started == 0 && /^#+ .*--feedback/ { started = 1; l = lvl($0); print; next }
		started == 0 && /--feedback/ { started = 2; print; next }
		started == 1 { if (/^#+ / && lvl($0) <= l) { started = 3; next } print; next }
		started == 2 { if (/^#+ /) { started = 3; next } print; next }
	' "$1" >"$2"
}
# has <file> <ERE>: case-insensitive search
has() { grep -qiE -- "$2" "$1"; }
# near <file> <ERE a> <ERE b>: one line (or two adjacent lines) holds both
near() { tr '\n' ' ' <"$1" | grep -qiE -- "($2).{0,200}($3)|($3).{0,200}($2)"; }

for sk in node triage; do
	f=$src/../plugin/skills/$sk/SKILL.md
	fbsec "$f" "$tmp/$sk.fb"
	case $sk in node) ac=G03-AC-7 ;; *) ac=G03-AC-8 ;; esac
	s=$tmp/$sk.fb
	ok "$ac: the $sk skill has a section about --feedback" test -s "$s"
	ok "$ac: it describes '--feedback <PR>' (the PR as its argument)" has "$s" '--feedback[ `]*(<PR>|<N>|PR)'
	ok "$ac: it describes --dry-run" has "$s" '--dry-run'
	ok "$ac: it reads FEEDBACK.md" has "$s" 'FEEDBACK\.md'
	ok "$ac: it never rebases or force-pushes" near "$s" 'never|no |not |without' 'rebase'
	ok "$ac: and names the force push" near "$s" 'never|no |not |without' 'force[- ]push'
	ok "$ac: it replies to each point" near "$s" 'repl(y|ies)' 'each|every'
	ok "$ac: it resolves the fixed line threads" near "$s" 'resolv' 'thread'
	ok "$ac: it writes QUESTION.md" has "$s" 'QUESTION\.md'
	ok "$ac: it pushes, and a --dry-run stops before the push" near "$s" 'dry-run' 'before .{0,20}push|no push|not push|without push|stops'
done

# ---- G03-AC-7: the node skill ----
s=$tmp/node.fb
ok "G03-AC-7: a point that changes behaviour goes through the test-first steps" near "$s" 'behaviou?r' 'test-first|tests? first|tdd'
ok "G03-AC-7: the tester's RED commit" has "$s" '\bRED\b'
ok "G03-AC-7: the implementer's GREEN" has "$s" '\bGREEN\b'
ok "G03-AC-7: and the review" near "$s" 'GREEN' 'review'
ok "G03-AC-7: a frozen test line is not changed: QUESTION.md instead" near "$s" 'frozen' 'QUESTION\.md'
ok "G03-AC-7: a fixture line is covered the same way" has "$s" 'fixture'
ok "G03-AC-7: a spec file is not changed: QUESTION.md instead" near "$s" 'spec file|specs?\b' 'QUESTION\.md'
ok "G03-AC-7: such points are not made (no such change)" near "$s" 'frozen|spec file' 'not (be )?(made|change)|never (chang|edit|modif)|no such|does not (change|edit)|must not|do not (change|edit|touch)'
ok "G03-AC-7: it reruns make test" has "$s" 'make test'
ok "G03-AC-7: and the red targets of the PR's table" near "$s" 'red target' 'rerun|re-run|run'
ok "G03-AC-7: it reruns the whole-node fresh review when the node's code changed" near "$s" 'whole[- ]node|whole node' 'fresh review|review'
ok "G03-AC-7: and says that is when the code changed" near "$s" 'whole[- ]node|fresh review' 'code (has )?changed|changed code|code change|changes? the code|when .{0,40}code'
ok "G03-AC-7: each reply says what changed, with the commit, or why nothing did" near "$s" 'commit' 'why (nothing|not)|nothing (did|changed)|no change'
ok "G03-AC-7: a line comment is answered in its own thread" near "$s" 'line comment' 'own thread|its thread|the thread'
ok "G03-AC-7: it never approves a review" near "$s" 'never|not|no ' 'approv'
ok "G03-AC-7: it never dismisses a review" near "$s" 'never|not|no ' 'dismiss'
ok "G03-AC-7: the dry run writes out/node/pr-<N>/result.md" has "$s" 'out/node/pr-(<N>|<PR>|N)/result\.md'
ok "G03-AC-7: the skill names no repository (no tuckermclean)" sh -c "! grep -qi tuckermclean '$src/../plugin/skills/node/SKILL.md'"
ok "G03-AC-7: and no owner/name literal anywhere in the skill" sh -c "! grep -qE '(github\.com/|(-R|--repo)[ =])[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' '$src/../plugin/skills/node/SKILL.md'"

# ---- G03-AC-8: the triage skill ----
s=$tmp/triage.fb
ok "G03-AC-8: the spec change follows the triage rules" near "$s" 'triage rules|rules of (the )?triage|as (a |the )?triage' 'spec|change'
ok "G03-AC-8: as one new commit" has "$s" 'one new commit|single new commit|one commit'
ok "G03-AC-8: never an amend" near "$s" 'never|no |not |without' 'amend'
ok "G03-AC-8: the spec checker is rerun until PROBLEMS 0" has "$s" 'PROBLEMS 0'
ok "G03-AC-8: QUESTION.md for a judgment only the owner can make" near "$s" 'judg(e)?ment' 'owner'
ok "G03-AC-8: the judgment goes to QUESTION.md" near "$s" 'judg(e)?ment' 'QUESTION\.md'
ok "G03-AC-8: the PR's title and body are updated" near "$s" 'title' 'body'
ok "G03-AC-8: the dry run writes out/triage/pr-<N>/result.md" has "$s" 'out/triage/pr-(<N>|<PR>|N)/result\.md'

echo "loop-g03-skills: $fails failure(s)"
[ "$fails" = 0 ]

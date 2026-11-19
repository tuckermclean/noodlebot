#!/bin/bash
# V02: the commit-msg hook joins the trailer-only paragraphs at the end of a session's commit message into one final
# trailer block. Part of the end-to-end test of scheduler/loop.sh; one loop run, one fake session making every commit shape.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# ---- V02: the trailer block ----
# The loop runs from a Git checkout $nbv (tag v7.0, one commit after it), so its version is known. The fake claude commits, in
# its worktree, every message $V02/in/<label> (verbatim, so the hook sees it as written); the test then compares each commit's
# message with $V02/exp/<label> and `git interpret-trailers --parse` with $V02/par/<label>.
nbv=$tmp/nbv datav=$tmp/datav V02=$tmp/v02 V02_CLONE=$tmp/datav/repos/pv
statev=$datav/state/pv
state=$statev   # ok prints this log on a failure
export V02 V02_CLONE V02_STATE=$statev
mkdir -p "$nbv/scheduler" "$nbv/plugin" "$datav/repos" "$statev/node" "$V02/in" "$V02/exp" "$V02/par" "$tmp/bin6"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$nbv/scheduler/"
[ -f "$src/harness.py" ] && { mkdir -p "$nbv/scheduler/harnesses"; cp "$src/harness.py" "$nbv/scheduler/"; cp "$src"/harnesses/*.py "$nbv/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$nbv/scheduler/forges"; cp "$src/forge.py" "$nbv/scheduler/"; cp "$src"/forges/*.py "$nbv/scheduler/forges/"; }
[ -f "$src/version.sh" ] && cp "$src/version.sh" "$nbv/scheduler/"
touch "$nbv/plugin/.keep"
git init -q -b main "$nbv"
git -C "$nbv" add -A && git -C "$nbv" -c user.name=t -c user.email=t@t commit -q -m v1
git -C "$nbv" tag v7.0
git -C "$nbv" -c user.name=t -c user.email=t@t commit -q --allow-empty -m v2
git -C "$nbv" remote add origin https://github.com/o/nbv.git
ver=$(git -C "$nbv" describe --tags --always)
git init -q -b main "$tmp/workv"; mkdir -p "$tmp/workv/docs"
printf 'nodes:\n  - {id: C01, name: only-node, deps: []}\n' >"$tmp/workv/docs/graph.yaml"
git -C "$tmp/workv" add -A && git -C "$tmp/workv" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/workv" "$tmp/remotev.git"
git clone -q "$tmp/remotev.git" "$V02_CLONE"

# The messages. msg <dir> <label> <line>...: one line per argument (an empty argument is a blank line).
msg() { local d=$1 l=$2; shift 2; printf '%s\n' "$@" >"$V02/$d/$l"; }
cmd='sh scheduler/foo.test.sh && sh plugin/skills/node/skill.test.sh'
co='Co-Authored-By: Claude <noreply@anthropic.com>'
nv="Noodlebot-Version: $ver"
pin1='Pin-Mutation: D01-AC-2: scheduler/a.test.sh: the check removed -> the case D01-AC-2 one'
pin2='Pin-Mutation: D01-AC-3: scheduler/a.test.sh: the loop broken -> the case D01-AC-3 two'
sub='test(X01): specify the thing'
export labels='red red-nv pin one-para tdd-last prose-before mixed fix-only fix-tdd'
# V02-AC-1: trailer-only paragraphs separated by blank lines are joined; trailers already in one paragraph give the same result
msg in red "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "" "$co"
msg exp red "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par red "TDD-Red-Target: $cmd" "$co" "$nv"
msg in red-nv "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "Noodlebot-Version: other-value" "" "$co"
msg exp red-nv "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par red-nv "TDD-Red-Target: $cmd" "$co" "$nv"
msg in pin "pin(X01): pin the dependency" "" "Pins the behaviour." "" "$pin1" "$pin2" "" "$co"
msg exp pin "pin(X01): pin the dependency" "" "Pins the behaviour." "" "$pin1" "$pin2" "$co" "$nv"
msg par pin "$pin1" "$pin2" "$co" "$nv"
msg in one-para "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "$co"
msg exp one-para "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par one-para "TDD-Red-Target: $cmd" "$co" "$nv"
msg in tdd-last "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd"
msg exp tdd-last "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "$nv"
msg par tdd-last "TDD-Red-Target: $cmd" "$nv"
# V02-AC-2: no paragraph with a line other than a trailer line is joined; a fix: subject stays the subject
pro='Why this change: the hook must not join prose.'
msg in prose-before "$sub" "" "$pro" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp prose-before "$sub" "" "$pro" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par prose-before "TDD-Red-Target: $cmd" "$co" "$nv"
mix1='The hook handles trailers.'; mix2='Note: this line only looks like a trailer.'; mix3='The rest of this paragraph is prose.'
msg in mixed "$sub" "" "$mix1" "$mix2" "$mix3" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp mixed "$sub" "" "$mix1" "$mix2" "$mix3" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par mixed "TDD-Red-Target: $cmd" "$co" "$nv"
msg in fix-only "fix: handle the empty case" "" "$co"
msg exp fix-only "fix: handle the empty case" "" "$co" "$nv"
msg par fix-only "$co" "$nv"
msg in fix-tdd "fix: handle the empty case" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp fix-tdd "fix: handle the empty case" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par fix-tdd "TDD-Red-Target: $cmd" "$co" "$nv"

cat >"$tmp/bin6/claude" <<'FAKE'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) exit 0 ;; esac
id=${2##* }
echo "${NOODLEBOT_VERSION-unset}" >"$V02/env.node"
for l in $labels; do
	git -c user.name=t -c user.email=t@t commit -q --allow-empty --cleanup=verbatim -F "$V02/in/$l" && echo "$l $(git rev-parse HEAD)" >>"$V02/commits"
done
echo "Q1: x" >"$V02_STATE/node/$id/QUESTION.md"
touch "$V02/done.node"
exit 0
FAKE
cat >"$tmp/bin6/gh" <<'FAKE'
#!/bin/sh
case " $* " in
*" --state merged "*) ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin6/claude" "$tmp/bin6/gh"
v02_done() { [ -e "$V02/done.node" ]; }
v02_gone() { ! kill -0 "$1" 2>/dev/null; }
NOODLEBOT_DATA=$datav PATH=$tmp/bin6:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nbv/scheduler/loop.sh" o/pv >"$tmp/pv.out" 2>&1 &
lpv=$!; pids+=("$lpv")
wait_until 20 v02_done
touch "$HOME/STOP-pv"
wait_until 5 v02_gone "$lpv"

# The commit-message checks. A label whose commit is missing fails every check (an empty sha is never a pass).
v02_sha() { awk -v l="$1" '$1 == l { print $2 }' "$V02/commits" 2>/dev/null; }
v02_msg() { git -C "$V02_CLONE" log -1 --format=%B "$1"; }
# every line kept, in order; only the blank lines between joined paragraphs and the Noodlebot-Version: lines of the final block gone
v02_exact() { [ -n "$1" ] && [ "$(v02_msg "$1")" = "$(cat "$V02/exp/$2")" ]; }
v02_parse() { [ -n "$1" ] && [ "$(v02_msg "$1" | git interpret-trailers --parse)" = "$(cat "$V02/par/$2")" ]; }
v02_onenv() { [ -n "$1" ] && [ "$(v02_msg "$1" | git interpret-trailers --parse | grep -c '^Noodlebot-Version:')" = 1 ] && v02_msg "$1" | git interpret-trailers --parse | grep -qxF "$nv"; }
v02_tdd() { [ -n "$1" ] && [ "$(git -C "$V02_CLONE" log -1 --format='%(trailers:key=TDD-Red-Target,valueonly)' "$1" | sed '/^$/d')" = "$cmd" ]; }
v02_noprose() { [ -n "$1" ] && ! v02_msg "$1" | git interpret-trailers --parse | grep -qF -- "$2"; }
v02_subj() { [ -n "$1" ] && [ "$(git -C "$V02_CLONE" log -1 --format=%s "$1")" = "$2" ]; }
# v02_lines <sha> <from> <to> <expected lines...>: those message lines are exactly these (the blank line before the trailers kept)
v02_lines() { local s=$1 a=$2 b=$3; shift 3; [ -n "$s" ] && [ "$(v02_msg "$s" | sed -n "${a},${b}p")" = "$(printf '%s\n' "$@")" ]; }
ok "V02 (harness): the fake session made its nine commits" sh -c "[ \$(wc -l <'$V02/commits' 2>/dev/null || echo 0) = 9 ]"
for l in red red-nv pin one-para tdd-last; do
	case $l in
	red) d="subject, prose, TDD-Red-Target: and Co-Authored-By: as paragraphs of their own" ;;
	red-nv) d="the same with another Noodlebot-Version: in the TDD-Red-Target: paragraph" ;;
	pin) d="a pin commit, two Pin-Mutation: lines as one paragraph, then Co-Authored-By:" ;;
	one-para) d="TDD-Red-Target: and Co-Authored-By: already in one last paragraph" ;;
	tdd-last) d="TDD-Red-Target: alone as the last paragraph" ;;
	esac
	s=$(v02_sha "$l")
	ok "V02-AC-1: $d: every line is kept in its order, only the blank lines between the joined paragraphs and the other Noodlebot-Version: lines are gone (exact text)" v02_exact "$s" "$l"
	ok "V02-AC-1: $d: git interpret-trailers --parse lists every trailer and the session's Noodlebot-Version:" v02_parse "$s" "$l"
	ok "V02-AC-1: $d: exactly one Noodlebot-Version: trailer, the session's version" v02_onenv "$s"
	case $l in pin) ;; *) ok "V02-AC-1: $d: git log --format='%(trailers:key=TDD-Red-Target,valueonly)' prints the command" v02_tdd "$s" ;; esac
done
for l in prose-before mixed fix-only fix-tdd; do
	case $l in
	prose-before) d="a prose paragraph directly before the trailers"; pr=$pro ;;
	mixed) d="a paragraph with one trailer-shaped line among prose directly before the trailers"; pr=$mix2 ;;
	fix-only) d="a fix: subject followed only by a trailer paragraph"; pr='fix: handle' ;;
	fix-tdd) d="a fix: subject, then TDD-Red-Target: and Co-Authored-By: paragraphs"; pr='fix: handle' ;;
	esac
	s=$(v02_sha "$l")
	ok "V02-AC-2: $d: no paragraph with a non-trailer line is joined, every line kept in its order (exact text)" v02_exact "$s" "$l"
	ok "V02-AC-2: $d: git interpret-trailers --parse lists the final block's trailers only" v02_parse "$s" "$l"
	ok "V02-AC-2: $d: git interpret-trailers --parse does not list the non-trailer paragraph" v02_noprose "$s" "$pr"
done
ok "V02-AC-2: a prose paragraph directly before the trailers keeps its blank line" v02_lines "$(v02_sha prose-before)" 3 4 "$pro" ""
ok "V02-AC-2: a paragraph with one trailer-shaped line among prose keeps its three lines and its blank line" v02_lines "$(v02_sha mixed)" 3 6 "$mix1" "$mix2" "$mix3" ""
ok "V02-AC-2: a fix: <text> subject followed only by a trailer paragraph stays the subject, with its blank line" sh -c "[ \"\$(git -C '$V02_CLONE' log -1 --format=%B '$(v02_sha fix-only)' | sed -n 1,2p)\" = \"\$(printf '%s\n' 'fix: handle the empty case' '')\" ]"
ok "V02-AC-2: a fix: subject then trailer paragraphs: the subject is still the subject" v02_subj "$(v02_sha fix-tdd)" 'fix: handle the empty case'
ok "V02-AC-2: a fix: subject then trailer paragraphs: git log prints the TDD-Red-Target: command" v02_tdd "$(v02_sha fix-tdd)"

# A commit in the clone outside any session (no NOODLEBOT_VERSION) with the RED shape is left exactly as written.
msg in outside "$sub" "" "The tests encode each criterion." "" "TDD-Red-Target: $cmd" "" "$co"
env -u NOODLEBOT_VERSION git -C "$V02_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty --cleanup=verbatim -F "$V02/in/outside" 2>/dev/null
ok "V02-AC-2: the clone has the commit-msg hook (the outside commit below passes through it)" test -x "$V02_CLONE/.git/hooks/commit-msg"
ok "V02-AC-2: a commit in the clone outside any session is left exactly as written, blank lines kept" sh -c "[ \"\$(git -C '$V02_CLONE' log -1 --format=%s)\" = '$sub' ] && [ \"\$(git -C '$V02_CLONE' log -1 --format=%B)\" = \"\$(cat '$V02/in/outside')\" ]"
ok "V02-AC-2: and it has no Noodlebot-Version: trailer" sh -c "! git -C '$V02_CLONE' log -1 --format=%B | grep -q '^Noodlebot-Version:'"

# ---- V02 (second review): more shapes, committed directly in the clone with the session's version (the hook runs as in a session) ----
# three trailer-only paragraphs at the end; a paragraph before them with only its first (or only its last) line trailer-shaped;
# a message that begins with blank lines (--cleanup=verbatim keeps them): the fix: subject is still the subject
f1='Note: only the first line looks like a trailer.'; f2='The rest of this paragraph is prose.'
l1='The first lines of this paragraph are prose.'; l2='Still prose, then a last line that looks like a trailer.'; l3='Note: only the last line looks like a trailer.'
v02_extra='three first last lead'
msg in three "$sub" "" "$pro" "" "TDD-Red-Target: $cmd" "" "$pin1" "$pin2" "" "$co"
msg exp three "$sub" "" "$pro" "" "TDD-Red-Target: $cmd" "$pin1" "$pin2" "$co" "$nv"
msg par three "TDD-Red-Target: $cmd" "$pin1" "$pin2" "$co" "$nv"
msg in first "$sub" "" "$f1" "$f2" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp first "$sub" "" "$f1" "$f2" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par first "TDD-Red-Target: $cmd" "$co" "$nv"
msg in last "$sub" "" "$l1" "$l2" "$l3" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp last "$sub" "" "$l1" "$l2" "$l3" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par last "TDD-Red-Target: $cmd" "$co" "$nv"
msg in lead "" "" "fix: handle the empty case" "" "TDD-Red-Target: $cmd" "" "$co"
msg exp lead "" "" "fix: handle the empty case" "" "TDD-Red-Target: $cmd" "$co" "$nv"
msg par lead "TDD-Red-Target: $cmd" "$co" "$nv"
for l in $v02_extra; do
	NOODLEBOT_VERSION=$ver git -C "$V02_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty --cleanup=verbatim -F "$V02/in/$l" 2>/dev/null \
		&& echo "$l $(git -C "$V02_CLONE" rev-parse HEAD)" >>"$V02/commits2"
done
v02_sha2() { awk -v l="$1" '$1 == l { print $2 }' "$V02/commits2" 2>/dev/null; }
for l in three first last lead; do
	case $l in
	three) d="TDD-Red-Target:, a Pin-Mutation: paragraph and Co-Authored-By: as three trailer-only paragraphs at the end"; a=AC-1; pr=$pro ;;
	first) d="a paragraph before the trailers whose first line only is trailer-shaped"; a=AC-2; pr=$f1 ;;
	last) d="a paragraph before the trailers whose last line only is trailer-shaped"; a=AC-2; pr=$l3 ;;
	lead) d="blank lines, then a fix: subject, then TDD-Red-Target: and Co-Authored-By: paragraphs"; a=AC-2; pr='fix: handle' ;;
	esac
	s=$(v02_sha2 "$l")
	ok "V02-$a: $d: every line kept in its order, only the blank lines between the joined trailer paragraphs and the other Noodlebot-Version: lines gone (exact text)" v02_exact "$s" "$l"
	ok "V02-$a: $d: git interpret-trailers --parse lists the final block's trailers and the session's Noodlebot-Version:" v02_parse "$s" "$l"
	ok "V02-$a: $d: exactly one Noodlebot-Version: trailer, the session's version" v02_onenv "$s"
	ok "V02-$a: $d: git log --format='%(trailers:key=TDD-Red-Target,valueonly)' prints the command" v02_tdd "$s"
	[ "$l" = three ] || ok "V02-AC-2: $d: git interpret-trailers --parse does not list the non-trailer paragraph" v02_noprose "$s" "$pr"
done
ok "V02-AC-1: three trailer-only paragraphs: every trailer is in one block with the Pin-Mutation: lines listed" sh -c "[ \"\$(git -C '$V02_CLONE' log -1 --format=%B '$(v02_sha2 three)' | git interpret-trailers --parse | grep -c '^Pin-Mutation:')\" = 2 ]"
ok "V02-AC-2: a first line only trailer-shaped: the paragraph keeps its two lines and its blank line" v02_lines "$(v02_sha2 first)" 3 5 "$f1" "$f2" ""
ok "V02-AC-2: a last line only trailer-shaped: the paragraph keeps its three lines and its blank line" v02_lines "$(v02_sha2 last)" 3 6 "$l1" "$l2" "$l3" ""
ok "V02-AC-2: blank lines then a fix: subject: the subject is still the fix: line (git log %s)" v02_subj "$(v02_sha2 lead)" 'fix: handle the empty case'
ok "V02-AC-2: blank lines then a fix: subject: the fix: line keeps its two blank lines before and the blank line after" v02_lines "$(v02_sha2 lead)" 1 4 "" "" "fix: handle the empty case" ""

loop_end

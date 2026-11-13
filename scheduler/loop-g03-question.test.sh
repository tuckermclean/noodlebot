#!/bin/bash
# G03: no feedback session starts while the unit has an unanswered QUESTION.md; a session that ends with QUESTION.md keeps FEEDBACK.md and the answered start has it. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
# AC-4: a spec PR's unit with a question nobody answered yet
p=$state/pr/13
mkdir -p "$p"
echo "Q1: which one?" >"$p/QUESTION.md"
g03_hold fbspec.13
fbadd 13 conversation 321 'first point'
wait_ticks 2
fbadd 13 conversation 322 'second point'
wait_ticks 2
ok "G03-AC-4: no feedback session starts while the unit has a QUESTION.md without ANSWER.md" runsis fbspec.13 0
ok "G03-AC-4: nothing is handed over meanwhile" test ! -e "$p/FEEDBACK.md"
echo "Q1: the first" >"$p/ANSWER.md"
ok "G03-AC-4: the answer ends the hold: held feedback starts at the first tick after" waitf 10 runsis fbspec.13 1
ok "G03-AC-4: its FEEDBACK.md holds both held items" sh -c "grep -qF '$(fburl 13 conversation 321)' '$GD/fbseen.fbspec.13.1' && grep -qF '$(fburl 13 conversation 322)' '$GD/fbseen.fbspec.13.1'"
ok "G03-AC-4: the answer was released as usual (answered/ has the question and the answer)" sh -c "ls '$p'/answered/*-QUESTION.md '$p'/answered/*-ANSWER.md >/dev/null 2>&1 && [ ! -e '$p/QUESTION.md' ]"
g03_release fbspec.13
ok "G03 setup: that session ends" waitf 10 g03_idle "$p"

# AC-5: a node's feedback session that ends with QUESTION.md keeps FEEDBACK.md; the answered start has it
x=$state/node/X01
g03_hold fbnode.11
touch "$GD/question.fbnode.11.1"
fbadd 11 conversation 131 'third point'
fbadd 11 line 132 'fourth point' path=src/b.py line=3
ok "G03-AC-5 setup: the feedback starts a node session" waitf 12 runsis fbnode.11 1
e0=$(g03_ends X01)
g03_release fbnode.11
ok "G03-AC-5: the session ends with QUESTION.md" waitf 10 test -e "$x/QUESTION.md"
ok "G03-AC-5: and the end is one status-log event" waitf 6 g03_endsis X01 $((e0 + 1))
ok "G03-AC-5: it keeps FEEDBACK.md in the unit" sh -c "grep -qF '$(fburl 11 conversation 131)' '$x/FEEDBACK.md' && grep -qF '$(fburl 11 line 132)' '$x/FEEDBACK.md'"
ok "G03-AC-5: and does not move it into answered/" sh -c "! ls '$x'/answered/*-FEEDBACK.md >/dev/null 2>&1"
wait_ticks 2
ok "G03-AC-5: nothing starts while the question is unanswered" runsis fbnode.11 1
echo "Q1: do both" >"$x/ANSWER.md"
ok "G03-AC-5: the answered start follows the answer, as a feedback session (/noodlebot:node --feedback 11)" waitf 10 runsis fbnode.11 2
ok "G03-AC-5: the answered start has the FEEDBACK.md the question run had" cmp -s "$GD/fbseen.fbnode.11.1" "$GD/fbseen.fbnode.11.2"
ok "G03-AC-5: with each item once" test "$(g03_nitems fbnode.11.2)" = 2
ok "G03-AC-5: it is not a plain node start (no /node X01 or /noodlebot:node X01)" runsis other.X01 0
ok "G03-AC-5: and the answer is released into answered/" sh -c "[ ! -e '$x/QUESTION.md' ] && ls '$x'/answered/*-ANSWER.md >/dev/null 2>&1"
ok "G03-AC-5: when the answered start ends with rc 0, FEEDBACK.md moves into answered/" waitf 10 sh -c "[ ! -e '$x/FEEDBACK.md' ] && ls '$x'/answered/*-FEEDBACK.md >/dev/null 2>&1"
g03_stop
loop_end

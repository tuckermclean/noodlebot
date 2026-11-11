#!/bin/bash
# G02: QUESTION.md and ANSWER.md, a follow-up branch's node. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
g02_loop 0
wait_ticks 1   # setup: the loop has run a tick (the main run was warm when it came to these cases)
# G02-AC-2: an end with QUESTION.md is one event and starts nothing until ANSWER.md exists.
g02_prs 207 CONFLICTING
ok "G02-AC-2: an update that writes QUESTION.md is started" waitf 8 g02_runsis 207 1
ok "G02-AC-2: its end with QUESTION.md is one status-log event naming PR #207" waitf 6 g02_evis 207 'QUESTION\.md' 1
g02_mvref main; g02_mvref node/N07-eta
wait_ticks 4
ok "G02-AC-2: with QUESTION.md and no ANSWER.md it is not started again, though main and its head moved" g02_runsis 207 1
ok "G02-AC-2: and the question end stays one event" g02_evis 207 'QUESTION\.md' 1
mkdir -p "$state/pr/207"; echo "A: this side" >"$state/pr/207/ANSWER.md"
ok "G02-AC-2: once ANSWER.md exists the update starts again" waitf 8 g02_runsis 207 2
ok "G02-AC-2: the answer is moved into pr/207/answered/" sh -c "ls '$state'/pr/207/answered/*ANSWER.md >/dev/null 2>&1 && [ ! -e '$state/pr/207/ANSWER.md' ] && [ ! -e '$state/pr/207/QUESTION.md' ]"
ok "G02-AC-2: its starts are reset: the second run is start 1 of 2 again" waitf 3 g02_evis 207 'start 1 of 2' 2
ok "G02-AC-2: the question is still one event" g02_evis 207 'QUESTION\.md' 1
g02_prs 207 MERGEABLE

# G02-AC-1: the node of a follow-up branch is the ID after node/.
echo "212 node/N12-nu-followup-1 app/noodlebot true CONFLICTING" >>"$G02_GD/prs.tsv"
ok "G02-AC-1: a follow-up's node PR (node/N12-nu-followup-1) gets an update" waitf 8 g02_runsis 212 1
ok "G02-AC-1: its node is N12" test "$(cat "$state/pr/212/node" 2>/dev/null)" = N12
g02_prs 212 MERGEABLE
g02_stop

loop_end

#!/bin/bash
# G06-AC-2: node feedback waits while pr/<N>/ holds a node-PR update's QUESTION.md without ANSWER.md; after the answer the answered update runs, ends, and then the feedback session starts with every held item. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g06.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g06.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G06 setup: the first tick records the open PRs' feedback" waitf 40 test -d "$state/feedback"
x=$state/node/X01 p=$state/pr/11
g03_hold nupd.11; g03_hold fbnode.11
rec=$(cat "$state/feedback/11" 2>/dev/null)   # the record before any of the new items
ok "G06 setup: the record feedback/11 exists" test -n "$rec"
# an update of node X01's PR 11 asked a question nobody has answered
mkdir -p "$p"; echo X01 >"$p/node"; echo "Q1: which side wins?" >"$p/QUESTION.md"
fbadd 11 conversation 121 'first point'
fbadd 11 line 122 'second point'
# the same ticks: a spec PR's feedback and a node PR without a question start as G03 says
fbadd 13 conversation 331 'spec point'
fbadd 12 conversation 231 'other node point'
ok "G06-AC-2 (G03 as before): a spec PR's feedback starts its session" waitf 20 runsis fbspec.13 1
ok "G06-AC-2 (G03 as before): a node PR without an update question starts its feedback session" waitf 20 runsis fbnode.12 1
wait_ticks 3 || fail "D13 setup: the loop ticks three more times before the unanswered-question checks (in $(basename "$0"))"
ok "G06-AC-2: no feedback session starts while the update's question is unanswered" runsis fbnode.11 0
ok "G06-AC-2: nothing is handed over (no FEEDBACK.md in the node's folder)" test ! -e "$x/FEEDBACK.md"
fbadd 11 conversation 123 'third point'
wait_ticks 2 || fail "D13 setup: the loop ticks twice more after the third item (in $(basename "$0"))"
ok "G06-AC-2: still no session after another item" runsis fbnode.11 0
ok "G06-AC-2: still no FEEDBACK.md" test ! -e "$x/FEEDBACK.md"
ok "G06-AC-2: the record feedback/11 is unchanged" test "$(cat "$state/feedback/11" 2>/dev/null)" = "$rec"

# the owner answers; the answered update runs (the PR conflicts) and the feedback waits for it
# The loop reads the PR list once a tick but the question hold live, twice in a tick (next_update, then fb_blocked before the
# feedback step): answer only after a tick that listed PR 11 as CONFLICTING is past its feedback step (it rewrites graph.yaml
# right after, and its heartbeat is older), so that no tick sees the answer in one read and not the other (it would start the
# feedback). Residual window: the test would have to stall between the check and the write for longer than the tick's tail,
# the pause's poll and the next tick's heartbeat-to-next_update time.
g06_prs 11 CONFLICTING
g06_listed() { grep -qE '^11 .* CONFLICTING$' "$state/open-prs.tsv" 2>/dev/null; }
waitf 40 g06_listed || fail "D13 setup: the loop lists PR 11 as CONFLICTING (in $(basename "$0"))"
g06_pastfb() { [ "$state/graph.yaml" -nt "$state/heartbeat" ]; }
waitf 40 g06_pastfb || fail "D13 setup: the tick that listed PR 11 as CONFLICTING is past its feedback step (in $(basename "$0"))"
echo "A1: ours" >"$p/ANSWER.md"
ok "G06-AC-2 setup: the answered update of PR 11 starts and runs" waitf 20 runsis nupd.11 1
wait_ticks 3 || fail "D13 setup: the loop ticks three more times while the answered update runs (in $(basename "$0"))"
ok "G06-AC-2: no feedback session starts while the answered update runs" runsis fbnode.11 0
ok "G06-AC-2: nothing handed over meanwhile" test ! -e "$x/FEEDBACK.md"
g03_release nupd.11
ok "G06-AC-2: once the answered update has ended, the feedback session starts" waitf 20 runsis fbnode.11 1
ok "G06-AC-2: the update did not start again" runsis nupd.11 1
ok "G06-AC-2: its FEEDBACK.md holds every held item" sh -c "grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 line 122)' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 conversation 123)' '$GD/fbseen.fbnode.11.1'"
g03_stop
loop_end

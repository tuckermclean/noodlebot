#!/bin/bash
# G02: review1d #1 and #3: an update cut off mid-merge, an ANSWER.md with no QUESTION.md. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"
. "$src/testdata/lib/loop-g02-review.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# review1d #1: an update cut off mid-merge (pr-250 left with unmerged paths) must not strand its node. N30 is
# idle with an open question; PR 250 is CONFLICTING; the update merges origin/main (conflict) and exits 1 twice
# (FAILED). The owner then merges main into the PR by hand (MERGEABLE) and answers N30: its session must start.
mkdir -p "$state/node/N30"; echo "Q: wait" >"$state/node/N30/QUESTION.md"
g02_prs 250 CONFLICTING
touch "$G02_GD/conflict.250"; echo 1 >"$G02_GD/rc.250.1"; echo 1 >"$G02_GD/rc.250.2"
g02b_loop 0 "$g02_data" 0
ok "G02-AC-2 (review1d #1): the update of 250 starts" waitf 10 g02_runsis 250 1
ok "G02-AC-2 (review1d #1): its second end without rc 0 writes FAILED" waitf 12 test -e "$state/pr/250/FAILED"
ok "G02-AC-2 (review1d #1 setup): the cut-off update left unmerged paths in worktrees/<name>/pr-250" sh -c "git -C '$g02_wt/pr-250' ls-files -u | grep -q ."
g02g checkout -q node/N30-aa && g02g merge -q -X ours main -m "owner merges main" >/dev/null && g02g push -q "$G02/remote.git" node/N30-aa; g02g checkout -q main
g02_prs 250 MERGEABLE
wait_ticks 2
echo "A: go" >"$state/node/N30/ANSWER.md"
ok "G02-AC-1 (review1d #1): the answered node N30 starts its session in worktrees/<name>/N30 on its branch, though pr-250 was cut off mid-merge" waitf 12 grep -qF "node N30 run 1 /noodlebot:node N30 | $g02_wt/N30 | node/N30-aa" "$G02_GD/claude.log"
ok "G02-AC-1 (review1d #1): N30's ANSWER.md is consumed (moved into answered/) only with its session started" sh -c "[ -e '$state/node/N30/ANSWER.md' ] || [ \"\$(cat '$G02_GD/runs.N30' 2>/dev/null || echo 0)\" -ge 1 ]"
ok "G02-AC-1 (review1d #1): the loop does not give up on N30 ('detaching ... failed' is not logged)" sh -c "! grep -q 'detaching .*pr-250.* failed' '$state/status.log'"
g02_stop
rm -f "$G02_GD/conflict.250"

# review1d #3: an ANSWER.md with no QUESTION.md does not skip the hold after an rc 0 end.
g02_prs 253 CONFLICTING
g02_loop 0
ok "G02-AC-2 (review1d #3): the update of 253 starts and ends with rc 0" waitf 10 g02_evis 253 'rc 0' 1
wait_ticks 3
ok "G02-AC-2 (review1d #3 setup): held after rc 0 while main and its head stay" g02_runsis 253 1
mkdir -p "$state/pr/253"; echo "A: stray" >"$state/pr/253/ANSWER.md"
wait_ticks 4
ok "G02-AC-2 (review1d #3): an ANSWER.md with no QUESTION.md does not skip the hold: 253 is not started again" g02_runsis 253 1
g02_prs 253 MERGEABLE
g02_stop

loop_end

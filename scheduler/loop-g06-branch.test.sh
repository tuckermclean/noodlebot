#!/bin/bash
# G06-AC-1: a node's feedback start takes the PR's branch back from the idle pr-<N> worktree an update left (its unpushed commit dropped) and puts the worktree the update detached back on the branch; the node's own commit is kept. Case 1: the node's worktree was detached by the update. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g06.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g06.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G06 setup: the first tick records the open PRs' feedback" waitf 40 test -d "$state/feedback"
x=$state/node/X01 br=node/X01-first
s=$(g06_leftover_setup 11 X01 $br detached)
nc=${s#node=}; nc=${nc%% *}; uc=${s##*upd=}
ok "G06 setup: node worktree X01 detached at a commit of its own, pr-11 holds the branch with the update's unpushed commit" test -n "$nc" -a -n "$uc" -a -e "$x/detached"
# the update ended FAILED (second exit without finishing)
mkdir -p "$state/pr/11"; echo X01 >"$state/pr/11/node"
echo "2018-01-01T00:00:00Z second exit (rc 1) without finishing the update" >"$state/pr/11/FAILED"
fbadd 11 conversation 141 'after the failed update'

ok "G06-AC-1: the node's feedback session starts in the node's worktree on the PR's branch" waitf 30 g06_fb 11 X01 $br 1
ok "G06-AC-1: the pr-11 worktree is detached" g06_detached "$wt6/pr-11"
ok "G06-AC-1: the update's unpushed commit is not on the branch" sh -c "! git -C '$clone' merge-base --is-ancestor $uc refs/heads/$br && ! git -C '$wt6/X01' merge-base --is-ancestor $uc HEAD"
ok "G06-AC-1: node/X01/detached is gone" test ! -e "$x/detached"
ok "G06-AC-1: the node's own commit is on the branch or under refs/noodlebot/leftover/" g06_kept "$nc" $br
ok "G06-AC-1: the status log has no 'checking out ... failed' and no 'feedback not started' line" sh -c "! grep -qE 'checking out .* failed|feedback not started' '$state/status.log'"
g03_stop
loop_end
